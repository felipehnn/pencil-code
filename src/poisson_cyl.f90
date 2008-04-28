! $Id: poisson_cyl.f90,v 1.6 2008-04-28 22:01:20 wlyra Exp $

!
!  This module solves the Poisson equation in cylindrical coordinates
!    (d^2/dr^2 +1/r*d/dr + 1/r^2*d^2/dy^2 + d^2/dz^2) f = RHS(x,y,z)
!
!  Another file was coded for the module because an extra tridimensional
!  array bessel_grid is needed to store the bessel functions of the grid.
!  Calculating them at every time would be time-consuming and unecessary
!  Instead, they are calculated in start time and stored in the memory. 
!
!  For now, this file only solves the 2d cylindrical poisson equation, 
!  with Hankel transforms, following the theory outlined by Toomre (1962)
!  and in Binney and Tremaine's "Galactic Dynamics" p.74-76   
!
!

!** AUTOMATIC CPARAM.INC GENERATION ****************************
! Declare (for generation of cparam.inc) the number of f array
! variables and auxiliary variables added by this module
!
! CPARAM logical, parameter :: lpoisson=.true.
!
! MVAR CONTRIBUTION 0
! MAUX CONTRIBUTION 0
!
!***************************************************************

module Poisson

  use Cdata
  use Cparam
  use Fourier
  use Messages

  implicit none

  real :: kmax=0.0
  logical :: lrazor_thin=.true.,lsolve_bessel=.false.,lsolve_cyl2cart=.false.
  logical :: lsolve_direct=.false.,lsolve_logspirals=.false.,lsolve_relax_sor=.false.
  character (len=labellen) :: ipoisson_method='nothing'

  integer, parameter :: mmax=8 !eight harmonics for the azimuthal direction

  include 'poisson.h'

  namelist /poisson_init_pars/ &
       kmax,lrazor_thin,ipoisson_method
  namelist /poisson_run_pars/ &
       kmax,lrazor_thin,ipoisson_method

!
! For the colvolution case, green functions
!

  real, dimension(nx,ny,nxgrid,nygrid) :: green_grid_2D
!
! For the Bessel and Hankel transforms, the grid of Bessel functions
!
  real, dimension(nx,nx,ny) :: bessel_grid
!
! For the 3D mesh relaxation, the functions for the border
!
  real, dimension(nx,nz,nxgrid,nzgrid,0:mmax) :: Legendre_Qmod
  real, dimension(ny,nygrid,0:mmax) :: fourier_cosine_terms
!
  real, dimension(nx,ny,nz) :: phi_previous_step,rhs_previous_step
  real, dimension(nx) :: rad,kr_fft,sqrtrad_1,rad1
  real, dimension(ny) :: tht
  real, dimension(nz) :: zed
  integer, dimension(nygrid) :: m_fft
  integer :: nr,nth,nkr,nkt,nthgrid
  integer :: nktgrid,nkhgrid
  real :: dr,dkr,dr1,dth,dth1,dz1
  real :: r0,theta0,rn,theta1

  contains

!***********************************************************************
    subroutine initialize_poisson()
!
!  Perform any post-parameter-read initialization i.e. calculate derived
!  parameters.
!
!  18-oct-07/anders: adapted
!
      integer :: i
!
      if (coord_system/='cylindric') then
        if (lroot) print*, 'poisson_cyl: '//&
             'this module is only for cylindrical runs'
        call fatal_error('initialize_poisson','')
      endif
!
      select case(ipoisson_method)

      case('bessel')
        if (lroot) print*,'Selecting the cylindrical '//&
             'Poisson solver that employs Bessel functions'
        lsolve_bessel    =.true.

      case('cyl2cart')
        if (lroot) print*,'Selecting the cylindrical '//&
             'Poisson solver that transforms to a periodic '//&
             'Cartesian grid and applies Fourier transforms there'
        lsolve_cyl2cart  =.true.

      case('directsum')
        if (lroot) print*,'Selecting the cylindrical '//&
             'Poisson solver that performs direct summation'
        lsolve_direct    =.true.

      case('logspirals')
        if (lroot) print*,'Selecting the cylindrical '//&
             'Poisson solver that uses the method of logarithmic spirals'
        lsolve_logspirals=.true.

      case('sor')
        if (lroot) print*,'Selecting the cylindrical '//&
             'Poisson solver that performs mesh-relaxation with SOR'
        lsolve_relax_sor=.true.

      case default
        !
        !  Catch unknown values
        !
        if (lroot) print*, 'initialize_poisson: '//&
             'No such value for ipoisson_method: ',&
             trim(ipoisson_method)
        call fatal_error('initialize_poisson','')
!
      endselect
!
      if (lrazor_thin) then
        if (nzgrid/=1) then
          if (lroot) print*, 'initialize_poisson: '//&
               'razor-thin approximation only works with nzgrid==1'
          call fatal_error('initialize_poisson','')
        endif
      else
        if (.not.lsolve_relax_sor) then 
          if (lroot) print*, 'initialize_poisson: '//&
               'not yet implemented for 3D cylindrical runs'
          call fatal_error('initialize_poisson','')
        endif
      endif
!
! Keep the notation consistent
!
      rad=x(l1:l2)     ; tht=y(m1:m2)
      nr =nx           ; nth=ny
      r0=rad(1)        ; theta0=xyz0(2)+.5*dth
      rn=rad(nr)       ; theta1=xyz1(2)-.5*dth
      dr=dx            ; dth=dy
      dr1=1./dr        ; dth1=1./dth
      nkr=nr           ; nkt=ny
      nktgrid=nygrid   ; nthgrid=nygrid
!
! For the 3D with SOR
!
      zed=z(n1:n2)     ; dz1=1./dz
      sqrtrad_1=1./sqrt(rad)
      rad1 = 1./rad
!
! Pre-calculate the radial wavenumbers
!         
      do i=1,nkr
        kr_fft(i)=.5*(i-1)/(nr*dr)
      enddo
      dkr=kr_fft(2)-kr_fft(1)
!
! Azimuthal wavenumbers (integers)
!
      m_fft=cshift((/(i-(nktgrid+1)/2,i=0,nktgrid-1)/),+(nktgrid+1)/2)
!
! This ones below are VERY time consuming
! Pre-calculate the special functions of the grid....
!
      if (lsolve_bessel) &
           call calculate_cross_bessel_functions
!
      if (lsolve_direct) &
           call calculate_cross_green_functions
!
      if (lsolve_relax_sor) &
           call calculate_cross_legendre_functions
!
    endsubroutine initialize_poisson
!***********************************************************************
    subroutine inverse_laplacian(phi,f)
!
!  Dispatch solving the Poisson equation to inverse_laplacian_fft
!  or inverse_laplacian_semispectral, based on the boundary conditions
!
!  17-jul-2007/wolf: coded wrapper
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (nx,ny,nz) :: phi
!
      intent(inout) :: phi
!
      if (lsolve_bessel) then
        call inverse_laplacian_bessel(phi)
      else if (lsolve_cyl2cart) then
        call inverse_laplacian_cyl2cart(phi)
      else if (lsolve_direct) then
        call inverse_laplacian_directsum(phi)
      else if (lsolve_relax_sor) then
        call inverse_laplacian_sor(phi,f)
      else 
        call fatal_error("inverse_laplacian","no solving method given")
      endif
!
    endsubroutine inverse_laplacian
!***********************************************************************
    subroutine inverse_laplacian_cyl2cart(phi)
!
!  Solve the 2D Poisson equation in cylindrical coordinates
!  by transforming to a periodic cartesian grid before 
!  Fourier transforming. 
!
!  This subroutine is faster than inverse_laplacian_bessel
!  for low resolutions and low number of processors.
!  But it gets slower when increasing any of them, 
!  due to the great amount of communication used. 
!
!  The frequent broadcast of a big array gave problems at the 
!  PIA cluster in Heidelberg after some thousands of time-steps. 
!  The problem was probably due to memory leaking. No problem occured 
!  at the UPPMAX cluster in Uppsala. So beware that using this broadcasting
!  extravaganza subroutine might not work in all clusters. 
!
!  01-12-07/wlad: coded
!  28-02-08/wlad: merged the serial and mpi versions
!
      use Mpicomm
!
      real, dimension (nx,ny,nz)  :: phi
      real, dimension (2*nx,2*ny) :: nphi,nb1
!
      real, dimension(nygrid) :: theta_serial
!
      real, dimension(2*nx)     :: xc,kkx_fft
      real, dimension(2*ny)     :: yc
      real, dimension(2*nygrid) :: kky_fft,yserial
!
! For communication
!
      real, dimension (nx,ny)         :: cross_proc
      real, dimension (2*nx,2*ny)     :: cross_proc_big
      real, dimension (nx,nygrid)     :: cross
      real, dimension (2*nx,2*nygrid) :: crossbig
!
! Cheap stuff
!
      real    :: x0,xn,y0,yn,dxc,dyc,dxc1,dyc1,Lxn,Lyn
      real    :: theta,radius,k2,xp,yp
      real    :: delr,delp,fr,fp,delx,dely,fx,fy
      real    :: p1,p2,p3,p4,interp_pot
!
      integer :: ix1,ix2,iy1,iy2,ir1,ir2,ip1,ip2
      integer :: i,j,ikx,iky,ir,im,ido,iup,ith
      integer :: nnx,nny,nnghost
      integer :: nnxgrid,nnygrid
!
      if (nx/=nygrid) &
           call fatal_error("inverse_laplacian_cyl2cart","currently only works for nx=nygrid")
      if (nzgrid/=1)  &
           call fatal_error("inverse_laplacian_cyl2cart","currently only works for 2D simulations")
!
! Expanded cartesian axes
!
      nnx=2*nx         ; nny=2*ny
      xn=2*rad(nr)     ; x0=-xn
      yn=xn            ; y0=-yn
      nnxgrid=2*nxgrid ; nnygrid=2*nygrid
!
      do i=1,nnx
        xc(i)=1.*(i-1)        /(nnxgrid-1)*(xn-x0)+x0
      enddo
      do m=1,nny
        yc(m)=1.*(m-1+ipy*nny)/(nnygrid-1)*(yn-y0)+y0
      enddo      
! 
      dxc=xc(2)-xc(1)  ; dyc=dxc
      dxc1=1/dxc       ; dyc1=1/dyc
!
! Now transform to Cartesian grid
!
      nnghost=npoint-nghost
!
      if (lmpicomm) then
!
! All processors send its density array to the root processor
!
        if (.not.lroot) then
          call mpisend_real(phi(:,:,nnghost),(/nx,ny/),root,111)
        else
          cross_proc=phi(:,:,nnghost)
!
! The root processor receives all arrays and
! stores them in a single big array of dimension
! nx*nygrid
!
          do j=0,ncpus-1
            if (j/=0) call mpirecv_real(cross_proc,(/nx,ny/),j,111)
            ido= j  * ny + 1
            iup=(j+1)*ny
            cross(:,ido:iup)=cross_proc
          enddo
        endif
!
! Broadcast the density field to all processors
!
        call mpibcast_real(cross,(/nx,nygrid/))
!
      else
!
! For serial runs, ny=nygrid, so just copy the density
!
        cross(:,1:ny)=phi(:,1:ny,nnghost)
!
      endif
!
! Need the serial theta later in order to compute the
! azimuthal displacement in parallel
!
      do i=1,nygrid
        theta_serial(i)=1.*(i-1)/(nthgrid-1)*(theta1-theta0)+theta0
      enddo
!
! Now transform the grid just like we would do in a serial run
!
      do m=1,nny
        do i=1,nnx
          radius=sqrt(xc(i)**2+yc(m)**2)
          if ((radius.ge.r0).and.(radius.le.rn)) then
            ir1=floor((radius-r0)*dr1 ) +1;ir2=ir1+1
            delr=radius-rad(ir1)
!
! this should never happen, but is here for warning
!
            if (ir1.lt.1 ) call fatal_error("cyl2cart","ir1<1")
            if (ir2.gt.nr) call fatal_error("cyl2cart","ir2>nr")
!
            theta=atan2(yc(m),xc(i))
            ip1=floor((theta - theta0)*dth1)+1;ip2=ip1+1
            if (ip1==0) then
              ip1=nthgrid
              delp=theta-theta_serial(ip1) + 2*pi
            else
              delp=theta-theta_serial(ip1)
            endif
            if (ip2==nthgrid+1) ip2=1
!
! Bilinear interpolation
!
            !p1=phi(ir1,ip1,nnghost);p2=phi(ir2,ip1,nnghost)
            !p3=phi(ir1,ip2,nnghost);p4=phi(ir2,ip2,nnghost)
            p1=cross(ir1,ip1);p2=cross(ir2,ip1)
            p3=cross(ir1,ip2);p4=cross(ir2,ip2)
!
            fr=delr*dr1
            fp=delp*dth1
!
            nphi(i,m)=fr*fp*(p1-p2-p3+p4) + fr*(p2-p1) + fp*(p3-p1) + p1
          else
            nphi(i,m)=0.
          endif
        enddo
      enddo
!
!  The right-hand-side of the Poisson equation is purely real.
!
      nb1=0.0
!
!  Forward transform (to k-space).
!
      call fourier_transform_xy_xy_other(nphi,nb1)
!
!  Solve Poisson equation
!
      Lxn=2*xc(nnx);Lyn=Lxn
!
      kkx_fft=cshift((/(i-(nnxgrid+1)/2,i=0,nnxgrid-1)/),+(nnxgrid+1)/2)*2*pi/Lxn
      kky_fft=cshift((/(i-(nnygrid+1)/2,i=0,nnygrid-1)/),+(nnygrid+1)/2)*2*pi/Lyn
!
      do iky=1,nny
        do ikx=1,nnx
          if ((kkx_fft(ikx)==0.0) .and. (kky_fft(iky+ipy*nny)==0.0)) then
            nphi(ikx,iky) = 0.0
            nb1(ikx,iky) = 0.0
          else
            if (.not.lrazor_thin) then
              call fatal_error("inverse_laplacian_cyl2cart","3d case not implemented yet")
!
!  Razor-thin approximation. Here we solve the equation
!    del2Phi=4*pi*G*Sigma(x,y)*delta(z)
!  The solution at scale k=(kx,ky) is
!    Phi(x,y,z)=-(2*pi*G/|k|)*Sigma(x,y)*exp[i*(kx*x+ky*y)-|k|*|z|]
!
            else
              k2 = (kkx_fft(ikx)**2+kky_fft(iky+ipy*nny)**2)
              nphi(ikx,iky) = -.5*nphi(ikx,iky) / sqrt(k2)
              nb1(ikx,iky)  = -.5*nb1(ikx,iky)  / sqrt(k2)
            endif
          endif
!
!  Limit |k| < kmax
!
          if (kmax>0.0) then
            if (sqrt(k2)>=kmax) then
              nphi(ikx,iky) = 0.
              nb1(ikx,iky) = 0.
            endif
          endif
        enddo
      enddo
!
!  Inverse transform (to real space).
!
      call fourier_transform_xy_xy_other(nphi,nb1,linv=.true.)
!
      if (lmpicomm) then
        if (.not.lroot) then
          call mpisend_real(nphi,(/nnx,nny/),root,222)
        else
          cross_proc_big=nphi
          !the root processor receives all arrays and
          !stores them in a single big array of dimension
          !nx*nygrid
          do j=0,ncpus-1
            if (j/=0) call mpirecv_real(cross_proc_big,(/nnx,nny/),j,222)
            ido= j   *nny+1
            iup=(j+1)*nny
            crossbig(:,ido:iup)=cross_proc_big
          enddo
        endif
        call mpibcast_real(crossbig,(/nnx,nnygrid/))
      else
        crossbig(:,1:nny)=nphi(:,1:nny)
      endif
!
!  Convert back to cylindrical
!
      yserial(1:nygrid)=xc(1:nygrid)
      do ith=1,Nth
        do ir=1,Nr
!
          xp=rad(ir)*cos(tht(ith))
          yp=rad(ir)*sin(tht(ith))
!
          ix1 = floor((xp-x0)*dxc1)+1 ; ix2 = ix1+1
          iy1 = floor((yp-y0)*dyc1)+1 ; iy2 = iy1+1
!
          if (ix1 .lt.  1)      call fatal_error("cyl2cart","ix1 lt 1")
          if (iy1 .lt.  1)      call fatal_error("cyl2cart","iy1 lt 1")
          if (ix2 .gt. nnxgrid) call fatal_error("cyl2cart","ix2 gt nnxgrid")
          if (iy2 .gt. nnygrid) call fatal_error("cyl2cart","iy2 gt nnygrid")
!
          delx=xp-     xc(ix1);fx=delx*dxc1
          dely=yp-yserial(iy1);fy=dely*dyc1
!
! Bilinear interpolation
!
          p1=crossbig(ix1,iy1);p2=crossbig(ix2,iy1)
          p3=crossbig(ix1,iy2);p4=crossbig(ix2,iy2)
!
          interp_pot=fx*fy*(p1-p2-p3+p4) + fx*(p2-p1) + fy*(p3-p1) + p1
!
          do n=1,nz
            phi(ir,ith,n)=interp_pot
          enddo
!
        enddo
      enddo
!
    endsubroutine inverse_laplacian_cyl2cart
!***********************************************************************
    subroutine inverse_laplacian_bessel(phi)
!
!  Solve the 2D Poisson equation in cylindrical coordinates
!
!  This beautiful and elegant theory for calculating the 
!  potential of thin disks using bessel functions and hankel 
!  transforms is not so useful numerically because of the 
!  ammount of integrations to perform. 
!
!  In any case, we managed to optimize the computations so that 
!  only 30% of the computational time is spent in this routine. 
!  The number is only slightly dependant on parallelization and 
!  resolution, as opposed to inverse_laplacian_cyl2cart.
!  
!  For example, having this 
!
!   do ikr=1,nkr
!     SS(ikr)=sum(bessel_grid(2:nr-1,ikr,ikt)*sigma_tilde_rad(2:nr-1))+&
!          .5*(bessel_grid( 1,ikr,ikt)*sigma_tilde_rad(1)             +&
!              bessel_grid(nr,ikr,ikt)*sigma_tilde_rad(nr))
!   enddo
!
!  instead of 
!
!    do ikr=1,nkr
!      tmp=bessel_grid(:,ikr,ikt)*sigma_tilde*rad
!      SS(ikr)=sum(tmp(2:nr-1))+.5*(tmp(1)+tmp(nr))
!    enddo
!
!  lead to a factor 2 speed up. That's a lot for a subroutine
!  that usually takes most of the computing time. So, think (twice) 
!  before you modify it.
!
!  At every wavelength, the density-potential pair in fourier space is
!
!   Phi_tilde_k = exp(-k|z|) Jm(k*r) ; Sigma_tilde_k =-k/(2piG) Jm(k*r)  
!
!  So, the total potential and the total spectral density is 
!
!   Phi_tilde  =          Int [ S(k) Jm(k*r) exp(-k|z|) ]dk  
!
!   Sigma_tilde=-1/(2piG) Int [ S(k) Jm(k*r) k] dk
! 
!  The function above is the Hankel transform of S(k), so S(k) 
!  is the inverse Hankel transform of Sigma_tilde
!
!   S(k)=-2piG Int[ Jm(k*r) Sigma_tilde(r,m) r] dr 
!
!  06-03-08/wlad: coded
!
      use Mpicomm
!
      real, dimension (nx,ny,nz)  :: phi,b1
      complex, dimension(nx) :: SS,sigma_tilde_rad,tmp,tmp2
      integer :: i,ir,ikr,ikt,nnghost
      real :: fac
!
      if (nx/=nygrid) &
           call fatal_error("inverse_laplacian_bessel","currently only works for nx=nygrid")
      if (nzgrid/=1)  &
           call fatal_error("inverse_laplacian_bessel","currently only works for 2D simulations")
      nnghost=npoint-nghost
!
! Fourier transform in theta 
! 
      call transp(phi,'y'); b1=0.
      call fourier_transform_x(phi,b1)
      call transp(phi,'y');call transp(b1,'y')
!
! SS is the hankel transform of the density
!
      fac=-.5*dr*dkr !actually, -2*pi*G = -.5*rhs_poisson_const
      do ikt=1,nkt 
!       
! Hankel transform of the fourier-transformed density
!
        sigma_tilde_rad=rad*cmplx(phi(:,ikt,nnghost),b1(:,ikt,nnghost))
        do ikr=1,nkr
          SS(ikr)=sum(bessel_grid(2:nr-1,ikr,ikt)*sigma_tilde_rad(2:nr-1))+&
               .5*(bessel_grid( 1,ikr,ikt)*sigma_tilde_rad(1)             +&
                   bessel_grid(nr,ikr,ikt)*sigma_tilde_rad(nr))
        enddo
!
! Sum up all the contributions to Phi
!
        do ir=1,nr
          tmp(ir)=sum(bessel_grid(ir,2:nkr-1,ikt)*SS(2:nkr-1))+&
               .5*(bessel_grid(ir,  1,ikt)*SS(1)+             &
                   bessel_grid(ir,nkr,ikt)*SS(nkr))
        enddo
        do n=1,nz
          phi(:,ikt,n)=real(tmp)
           b1(:,ikt,n)=aimag(tmp)
        enddo
      enddo
!
! Transform back to real space
!
      call transp(phi,'y');call transp(b1,'y')
      call fourier_transform_x(phi,b1,linv=.true.)
      call transp(phi,'y')
!
      phi=phi*fac
!
    endsubroutine inverse_laplacian_bessel
!***********************************************************************
    subroutine inverse_laplacian_directsum(phi)
!
!  Solve the 2D Poisson equation in cylindrical coordinates
!
!  Direct summation phi=-G Int(rho/|r-r'| dV)
!
!  23-04-08/wlad: coded
!
      use Mpicomm
!
      real, dimension (nx,ny,nz)  :: phi
      real, dimension (nx,nygrid) :: cross,integrand
      real, dimension (nx,ny)     :: tmp,cross_proc
      real, dimension (nx)        :: intr
      integer :: ith,ir,ikr,ikt,imn
      integer :: nnghost,i,j,ido,iup
      real :: fac
!
      if (nzgrid/=1)  &
           call fatal_error("inverse_laplacian_directsum","currently only works for 2D simulations")
      nnghost=npoint-nghost

      !transfer fac to the green grid
      !fac=-.25*pi_1 !actually, -G = rhs_poisson_const/4*pi
!
      if (lmpicomm) then
!
! All processors send its density array to the root processor
!
        if (.not.lroot) then
          call mpisend_real(phi(:,:,nnghost),(/nx,ny/),root,111)
        else
          cross_proc=phi(:,:,nnghost)
!
! The root processor receives all arrays and
! stores them in a single big array of dimension
! nx*nygrid
!
          do j=0,ncpus-1
            if (j/=0) call mpirecv_real(cross_proc,(/nx,ny/),j,111)
            ido= j  * ny + 1
            iup=(j+1)*ny
            cross(:,ido:iup)=cross_proc
          enddo
        endif
!
! Broadcast the density field to all processors
!
        call mpibcast_real(cross,(/nx,nygrid/))
!
      else
!
! For serial runs, ny=nygrid, so just copy the density
!
        cross(:,1:ny)=phi(:,1:ny,nnghost)
!
      endif
!
! Now integrate through direct summation
!
      do ir=1,nr 
      do ith=1,nth
!
! the scaled green function already has the r*dr*dth term
!
        integrand=cross*green_grid_2D(ir,ith,:,:)
!
        phi(ir,ith,1:nz)=sum(                    &
             sum(integrand(2:nr-1,:)) +          &
             .5*(integrand(1,:)+integrand(nr,:)) &
                       )
!
      enddo
      enddo
!
    endsubroutine inverse_laplacian_directsum
!***********************************************************************
    subroutine inverse_laplacian_sor(phi,f)
!
!  Solve the 3D Poisson equation in cylindrical coordinates by 
!  using mesh-relaxation with the SOR algorithm. The borders have
!  to be pre-computed. For this, we use the analytical expression
!  of Cohl and Tohline (1999) using expansions in Legendre polinomials
! 
!  This is very expensive and does not need to be done every time. Just 
!  when the potential has changed by some small threshold
!
!  23-04-08/wlad: coded
!
      use Mpicomm
      use Sub, only: del2
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (nx,ny,nz)  :: phi,rhs,b1,b1_rhs
!      real, dimension (nx,ny,nz), save :: norm0
      real, dimension (nx) :: norm0,norm
      real, dimension (nx) :: a_band,b_band,c_band,d_band
      real, dimension (nx) :: e_band,b_band1,del2phi
      integer :: ir,ith,iz,im,i
      logical :: lfirst_timestep
      logical, dimension(nx,nz) :: lupdate
      logical, dimension(nx,ny,nz) :: lupdate_grid
      !logical, dimension(ny,nz,2) :: lupdate_radial_border
      !logical, dimension(nx,ny,2) :: lupdate_vertical_border
      logical, save :: lfirstcall=.true.!,lcompute_norm0=.true.
!
      if (nzgrid==1)  &
           call fatal_error("inverse_laplacian_sor","This method uses the "//&
           "discretized Poisson equation. It cannot be used for 2d in the r-phi plane")
!
      if (nprocz/=1) &
           call fatal_error("inverse_laplacian_sor","Not yet implemented for z "//&
           "parallelization. Put all processors in the azimuthal direction")
! 
! Upon re-starting, get the stored potential
!
      if ((it==1).and.(t.ne.0)) &
           phi_previous_step=f(l1:l2,m1:m2,n1:n2,ipotself)
!
! Integrate the border. In the first time step, sets the potential to the whole grid
! The call to check update is to make sure we really need to update the border
!
      rhs=phi
      if (.not.lfirstcall) then
        !if (lcompute_norm0) then 
        do m=m1,m2;do n=n1,n2
          ith=m-nghost;iz=n-nghost
          call del2(f,ipotself,del2phi)
          norm0=abs(del2phi - rhs_previous_step(:,ith,iz))
          norm=abs(del2phi - rhs(:,ith,iz))
          do i=l1,l2
            ir=i-nghost
            if (abs(norm(ir)-norm0(ir))/norm(ir) .lt. 1e-3) then 
              lupdate_grid(ir,ith,iz)=.false.  
            else
              lupdate_grid(ir,ith,iz)=.true.  
            endif
            !print*,norm(ir),norm0(ir),abs(norm(ir)-norm0(ir))/norm(ir)
          enddo
        enddo;enddo
      endif
      rhs_previous_step=rhs
!
        !call check_update_border(rhs,f,&
        !     lupdate_radial_border,lupdate_vertical_border,norm0)
!
      call get_border_values(rhs,phi,lfirstcall,lupdate_grid)
!           lupdate_radial_border,lupdate_vertical_border)
!
! For the other time-steps, the potential is known, so use discretization 
! of the 5-point formula (in fourier space) to determine the potential
!
      if (.not.lfirstcall) then
!
! Get the phi from the previous time step, apart from the newly updated boundaries
!
        if (nprocz >= 2) then 
          if (ipz==0) then 
            phi(2:nr-1,:,2:nz)=phi_previous_step(2:nr-1,:,2:nz)
          elseif (ipz==nprocz-1) then 
            phi(2:nr-1,:,1:nz-1)=phi_previous_step(2:nr-1,:,1:nz-1)
          else
            phi(2:nr-1,:,:)=phi_previous_step(2:nr-1,:,:)
          endif
        else
          phi(2:nr-1,:,2:nz-1)=phi_previous_step(2:nr-1,:,2:nz-1)
        endif
!
      endif
!
! Fourier transform the potential and the right-hand-side
!
      call transp(phi,'y'); b1=0.
      call fourier_transform_x(phi,b1)
      call transp(phi,'y');call transp(b1,'y')        
!
      call transp(rhs,'y'); b1_rhs=0.
      call fourier_transform_x(rhs,b1_rhs)
      call transp(rhs,'y');call transp(b1_rhs,'y')        
!
! Solve the five point matrix in fourier space
!
      a_band= dr1**2 - .5*dr1*rad1
      c_band= dr1**2 + .5*dr1*rad1
      d_band= dz1**2
      e_band= dz1**2
!
      if (lroot.and.ip<=8) print*,'initializing the iterations '//&
           'to solve the Poisson equation in the grid'
!
      do im=1,nkt
!
        b_band=-2*(dr1**2 + dz1**2) - m_fft(im+ipy*nkt)**2
        b_band1=1/b_band
!          
! check the points that need updating, then call the five point solver, in both
! real and imaginary parts
!
        !call check_update_grid(phi(:,im,:),rhs(:,im,:),a_band,b_band1,c_band,d_band,e_band,lupdate)
        call five_point_solver(phi(:,im,:),rhs(:,im,:),&
             a_band,b_band,b_band1,c_band,d_band,e_band,im,lupdate)
!
        !call check_update_grid(b1(:,im,:),b1_rhs(:,im,:),a_band,b_band1,c_band,d_band,e_band,lupdate)
        call five_point_solver(b1(:,im,:),b1_rhs(:,im,:),&
             a_band,b_band,b_band1,c_band,d_band,e_band,im,lupdate)
!
      enddo
!
! Fourier transform back to real space
!
      call transp(phi,'y');call transp(b1,'y')
      call fourier_transform_x(phi,b1,linv=.true.)
      call transp(phi,'y')
!
      lfirstcall=.false.
!
! Save the phi from the previous step
!
      phi_previous_step=phi
!
    endsubroutine inverse_laplacian_sor
!*******************************************************************************
    subroutine five_point_solver(lhs,rhs,&
         a_band,b_band,b_band1,c_band,d_band,e_band,im,lupdate)
    
      real, dimension (nx,nz) :: lhs,rhs,lhs_old
      real, dimension (nx) :: a_band,b_band,c_band,d_band,e_band,b_band1
      real :: omega,threshold,norm,sig,norm_old,anorm,rjac,resid
      integer :: n,i,iteration,im
      logical, dimension(nx,nz) :: lupdate
!
! Spectral radius and omega 
!
      omega=1 ; threshold=1e-3
      sig=1e5 ; norm=1e5
      rjac=(cos(pi/nr) + (dr/dz)**2*cos(pi/nz))/(1+(dr/dz)**2)

!
      lhs_old=lhs
!
      iteration=0
!
      do while (sig .gt. threshold)
        iteration=iteration+1
        do n=2,nz-1
          do i=2,nr-1
            !chebychev : odd-even ordering
            if (mod(n+i,2) .ne. (mod(iteration,2))) then
              if (lupdate(i,n)) then
                resid=  a_band(i)*lhs(i-1,n)+      &
                        c_band(i)*lhs(i+1,n)+      &
                        d_band(i)*lhs(i,n+1)+      &
                        e_band(i)*lhs(i,n-1)+      & 
                        b_band(i)*lhs(i,n) - rhs(i,n)
                anorm=anorm+abs(resid)
                lhs(i,n)=lhs(i,n)-omega*resid*b_band1(i)
              endif
            endif
          enddo
        enddo
        
        if (iteration==1) then 
          omega=1./(1-.5 *rjac**2)
        else
          omega=1./(1-.25*rjac**2*omega)
        endif
!
! error of the iteration
!
        norm_old=norm
        norm=sum((lhs-lhs_old)**2)
        sig=abs(norm-norm_old)/norm
!
      enddo
!
      !print*,'number of iterations',iteration,im
!
    endsubroutine five_point_solver
!***********************************************************************
    subroutine get_border_values(rhs,phi,lfirstcall,lupdate_grid)!&
!         lupdate_radial_border,lupdate_vertical_border)
!
      use Mpicomm
!
      real, dimension (nx,ny,nz) :: rhs,phi,rhs_proc
      real, dimension (nx,nygrid,nzgrid)  :: rhs_serial
      logical :: lfirstcall
      integer :: j,jy,jz,iydo,iyup,izdo,izup
      integer :: ir,ith,iz,skipped
      real    :: potential
      logical, dimension(nx,ny,nz) :: lupdate_grid 
      !logical, dimension(nx,ny,2) :: lupdate_vertical_border 
      !logical, dimension(ny,nz,2) :: lupdate_radial_border
!
! Construct the serial density
!
      if (lmpicomm) then
        if (.not.lroot) then
          call mpisend_real(rhs,(/nx,ny,nz/),root,111)
        else
          do jy=0,nprocy-1
            do jz=0,nprocz-1
              j=jy+nprocy*jz
              if (j/=0) then 
                call mpirecv_real(rhs_proc,(/nx,ny,nz/),j,111)
              else
                rhs_proc=rhs
              endif
              iydo= jy  * ny + 1 ; izdo= jz  * nz + 1 
              iyup=(jy+1)*ny     ; izup=(jz+1)*nz     
              rhs_serial(:,iydo:iyup,izdo:izup)=rhs_proc
            enddo
          enddo
        endif
        call mpibcast_real(rhs_serial,(/nx,nygrid,nzgrid/))
      else
        rhs_serial(:,1:ny,1:nz)=rhs(:,1:ny,1:nz)
      endif
!
! At the first time step, calculate the potential by integration, everywhere
!
      if (lfirstcall) then
! 
        if ((lroot).and.(ip<=8)) then 
          print*,'get_border_values: integrating the distribution everywhere'
          print*,'it will take a lot of time, so go grab a coffee...'
        endif
!
        do ir=1,nr;do ith=1,ny;do iz=1,nz
          call integrate_border(rhs_serial,ir,ith,iz,potential)
          phi(ir,ith,iz)=potential
        enddo;enddo;enddo
!
      else
        skipped=0
        if ((lroot).and.(ip<=8)) then 
          print*,'get_border_values: integrating the border values only'
        endif
          !just recompute the border
        do iz=1,nz;do ith=1,nth
          !if (lupdate_radial_border(ith,iz,1)) then
          if (lupdate_grid(1,ith,iz)) then 
            call integrate_border(rhs_serial,1,ith,iz,potential)
            phi(1,ith,iz)=potential
          else
            skipped=skipped+1
            phi(1,ith,iz)=phi_previous_step(1,ith,iz)
          endif
        enddo;enddo
        if ((lroot).and.(ip<=8)) print*,'done for ir=1'
!
        do iz=1,nz;do ith=1,nth
!          if (lupdate_radial_border(ith,iz,2)) then
          if (lupdate_grid(nr,ith,iz)) then 
            call integrate_border(rhs_serial,nr,ith,iz,potential)
            phi(nr,ith,iz)=potential
          else
            skipped=skipped+1
            phi(nr,ith,iz)=phi_previous_step(nr,ith,iz)
          endif
        enddo;enddo
        if ((lroot).and.(ip<=8)) print*,'done for ir=nr'
!
        if (ipz==0) then 
          do ir=2,nr-1;do ith=1,nth
!            if (lupdate_radial_border(ir,ith,1)) then
            if (lupdate_grid(ir,ith,1)) then 
              call integrate_border(rhs_serial,ir,ith,1,potential)
              phi(ir,ith,1)=potential
            else
              skipped=skipped+1
              phi(ir,ith,1)=phi_previous_step(ir,ith,1)
            endif
          enddo;enddo
        endif
        if ((lroot).and.(ip<=8)) print*,'done for iz=1'
!
        if (ipz==nprocz-1) then 
          do ir=2,nr-1;do ith=1,nth
!            if (lupdate_radial_border(ir,ith,2)) then
            if (lupdate_grid(ir,ith,nz)) then 
              call integrate_border(rhs_serial,ir,ith,nz,potential)
              phi(ir,ith,nz)=potential
            else
              skipped=skipped+1
              phi(ir,ith,nz)=phi_previous_step(ir,ith,nz)
            endif
          enddo;enddo
        endif
        if ((lroot).and.(ip<=8)) print*,'done for iz=nz'
!
        if ((lroot).and.(ip<=8)) &
             print*,'border: skipped ',skipped,' of ',2*nth*(nz+nr-2)
!
      endif !lfirst_timestep

    endsubroutine get_border_values
!**********************************************************************************
    subroutine integrate_border(rhs_serial,ir,ith,iz,potential)
!
      real, dimension(nx,nygrid,nzgrid) :: rhs_serial
      real, dimension (nx) :: intr
      real, dimension (nygrid) :: intp
      real, dimension (nzgrid) :: intz
!
      real :: summation_over_harmonics,potential,fac
      integer :: ir,ith,iz,ikr,ikt,ikz,im
!
! as rhs already the 4*pi*G factor built in, the factor -G/pi in front of
! the integral becomes 1/(4*pi^2)
!
      fac=-.25*pi_1**2*sqrtrad_1(ir)
!
      do ikz=1,nzgrid
        do ikt=1,nthgrid
          do ikr=1,nr
!
            summation_over_harmonics=0
! The Legendre function here is modified by including
! the jacobian, the division by sqrt(rad) and the neumann
! epsilon factor
            do im=0,mmax
              summation_over_harmonics=summation_over_harmonics+&
                   Legendre_Qmod(ir,iz,ikr,ikz,im)*fourier_cosine_terms(ith,ikt,im)
            enddo
            intr(ikr)=rhs_serial(ikr,ikt,ikz)*summation_over_harmonics
          enddo
          intp(ikt)=sum(intr(2:nr-1))+.5*(intr(1)+intr(nr))
        enddo
        intz(ikz)=sum(intp)  !this is phi-periodic
      enddo
!
      potential=fac*(sum(intz(2:nzgrid-1))+.5*(intz(1)+intz(nzgrid)))
!  
    endsubroutine integrate_border
!***********************************************************************
    subroutine check_update_grid(rhs,phi_old,a_band,b_band1,c_band,d_band,e_band,lupdate)
!
! Check if an update is needed. Otherwise, don't update the lhs
!
      real, dimension(nx,nz), intent(in) :: rhs,phi_old
      real, dimension(nx,nz)  :: lhs
      real, dimension(nx) :: a_band,b_band1,c_band,d_band,e_band
      logical, dimension(nx,nz), intent(out) :: lupdate
      real :: threshold,norm
      integer :: i,n,skipped
!
      threshold=1e-4
!      
      skipped=0
      do n=2,nz-1;do i=2,nr-1
        lhs(i,n)=b_band1(i)*(rhs(i,n) &
             - a_band(i)*phi_old(i-1,n)      &
             - c_band(i)*phi_old(i+1,n)      &
             - d_band(i)*phi_old(i,n+1)      &
             - e_band(i)*phi_old(i,n-1)    )
!
! don't update if it hadn't change by a significant amount
!
        norm=abs(lhs(i,n)-phi_old(i,n))!/max(abs(phi_old(i,n)),abs(lhs(i,n))))
        if (norm .le. threshold) then
          skipped=skipped+1
          lupdate(i,n)=.false.
        else
          lupdate(i,n)=.true.
        endif
!
      enddo;enddo
!
      if (ldebug) print*,' grid: skipped ',skipped,' of ',2*ny*(nz+nx-4)
!
    endsubroutine check_update_grid
!***********************************************************************
    subroutine check_update_border(rhs,f,lupdate_radial_border,&
         lupdate_vertical_border,norm0)
!
! Check if an update is needed. Otherwise, don't update the lhs
!
      use Sub,only:del2
!
      real, dimension(mx,my,mz,mfarray) :: f
      real, dimension(nx,ny,nz), intent(in) :: rhs,norm0
      logical, dimension(ny,nz,2), intent(out) :: lupdate_radial_border
      logical, dimension(nx,ny,2), intent(out) :: lupdate_vertical_border
      real :: threshold
      integer :: i,n,ith,iz,ir

      real, dimension (nx) :: del2phi,nnn
      real  :: norm
      logical :: lfirstcall
!
      threshold=1e-4      
!
!  compute del2phi and compare it with 4piGrho
!  as it has discretization errors, compare it with 
!  the one computed at the beginning of the calculations
!
      do m=m1,m2;do n=n1,n2
!
        ith=m-nghost;iz=n-nghost
!
        call del2(f,ipotself,del2phi)
!        
        nnn=abs(del2phi - rhs(:,ith,iz))!/rhs(:,ith,iz)
!
        norm=abs(del2phi(1) - rhs(1,ith,iz))!/rhs(1,ith,iz)
        if (norm/norm0(1,ith,iz) .lt. threshold) then 
          lupdate_radial_border(ith,iz,1)=.false.
        else
          lupdate_radial_border(ith,iz,1)=.true.
        endif

        norm=abs(del2phi(nr) - rhs(nr,ith,iz))!/rhs(nr,ith,iz)
        if (norm/norm0(nr,ith,iz) .lt. threshold) then 
          lupdate_radial_border(ith,iz,2)=.false.
        else
          lupdate_radial_border(ith,iz,2)=.true.
        endif
!      
        if ((ipz==0).and.(iz==1)) then 
          do ir=2,nr-1
            norm=abs(del2phi(ir)-rhs(ir,ith,1))!/rhs(ir,ith,1)
            if (norm/norm0(ir,ith,1) .lt. threshold) then 
              lupdate_vertical_border(ir,ith,1)=.false.
            else
              lupdate_vertical_border(ir,ith,1)=.true.
            endif
          enddo
        endif
!
        if ((ipz==nprocz-1).and.(iz==nz)) then 
          do ir=2,nr-1
            norm=abs(del2phi(ir)-rhs(ir,ith,nz))!/rhs(ir,ith,nz)
            if (norm/norm0(ir,ith,nz) .lt. threshold) then 
              lupdate_vertical_border(ir,ith,2)=.false.
            else
              lupdate_vertical_border(ir,ith,2)=.true.
            endif
          enddo
        endif
      enddo;enddo
!
    endsubroutine check_update_border
!********************************************************************************
    subroutine calculate_cross_bessel_functions
!
!  Calculate the Bessel functions related to the 
!  cylindrical grid
!
!     bessel_grid(ir,ikr,m)=J_m(kr(ikr)*rad(ir))
!
!  06-03-08/wlad: coded
!
      use General,only: besselj_nu_int
!
      real    :: tmp,arg
      integer :: ir,ikr,ikt
!
      if (lroot) &
        print*,'Pre-calculating the Bessel functions to '//&
        'solve the Poisson equation'
!
      do ikt=1,nkt
        do ir=1,nr;do ikr=1,nkr
          arg=kr_fft(ikr)*rad(ir)
          call besselj_nu_int(tmp,m_fft(ikt+ipy*nkt),arg)
          bessel_grid(ir,ikr,ikt)=tmp
        enddo;enddo
      enddo
!
      if (lroot) &
           print*,'calculated all the needed functions'
!
    endsubroutine calculate_cross_bessel_functions
!***********************************************************************
    subroutine calculate_cross_green_functions
!
!  Calculate the Green functions related to the 
!  cylindrical grid (modified by the jacobian, the 
!  gravitaional costant and the grid elements to 
!  ease the amount of calculations in runtime)
!
!     green_grid(ir,ip,ir',ip')=-G./|r-r'| * r*dr*dth
!
!  06-03-08/wlad: coded
!
      use Mpicomm
!
      real, dimension(nygrid) :: tht_serial
      real    :: jacobian,tmp,Delta,fac
      integer :: ir,ith,ikr,ikt
!
      if (lroot) &
        print*,'Pre-calculating the Green functions to '//&
        'solve the Poisson equation'
!
      fac=-.25*pi_1 ! -G = -rhs_poisson_const/4*pi
!
! Serial theta to compute the azimuthal displacement in parallel
!
      call get_serial_array(tht,tht_serial,'y')
!
! Define the smoothing length as the minimum resolution element present
!
      Delta=min(dr,dth)
!
      do ir =1,nr;do ith=1,nth
      do ikr=1,nr;do ikt=1,nthgrid
!
        jacobian=rad(ikr)*dr*dth
!
        tmp=sqrt(Delta**2 + rad(ir)**2 + rad(ikr)**2 - &
             2*rad(ir)*rad(ikr)*cos(tht(ith)-tht_serial(ikt)))
!
        green_grid_2D(ir,ith,ikr,ikt)= fac*jacobian/tmp
!
      enddo;enddo
      enddo;enddo
!
      if (lroot) &
           print*,'calculated all the needed green functions'
!
    endsubroutine calculate_cross_green_functions
!***********************************************************************
    subroutine calculate_cross_legendre_functions
!
      use General, only: calc_complete_elliptic_integrals
!
      real, dimension(mmax)   :: Legendre_Q
      real, dimension(nzgrid) :: zed_serial
      real, dimension(nygrid) :: tht_serial
      integer, dimension(mmax) :: neumann_factor_eps
      real    :: chi,mu,Kappa_mu,E_mu,jac
      integer :: ir,ith,iz,ikr,ikt,ikz
      integer :: j,im
!
      if (lroot) &
        print*,'Pre-calculating the half-integer Legendre functions '//&
        'of second kind to solve the Poisson equation'     
!
! Get serial z's
!
      if (nprocz /= 1) then
        call get_serial_array(zed,zed_serial,'z')
      else
        zed_serial(1:nz)=zed(1:nz)
      endif
!
      do ir=1,nr;do iz=1,nz        !for all points in this processor 
      do ikr=1,nr;do ikz=1,nzgrid  !integrate over the whole r-z grid
!
! Jacobian
!
        jac=rad(ikr)*dr*dth*dz 
!
! Calculate the elliptic integrals
! 
       chi=(rad(ir)**2+rad(ikr)**2+(zed(iz)-zed_serial(ikz))**2)/(2*rad(ir)*rad(ikr))
        mu=sqrt(2./(1+chi))
        call calc_complete_elliptic_integrals(mu,Kappa_mu,E_mu)
!
! Calculate the Legendre functions for each harmonic
!
        Legendre_Q(0)=    mu*Kappa_mu
        Legendre_Q(1)=chi*mu*Kappa_mu - (1+chi)*mu*E_mu
!
        do im=0,mmax
          if (im == 0) then
            neumann_factor_eps(im)=1
          else
            neumann_factor_eps(im)=2
            if (im >= 2) then 
              Legendre_Q(im)= &
                   4*(im-1)/(2*im-1)*chi*Legendre_Q(im-1) - &
                   (2*im-3)/(2*im-1)    *Legendre_Q(im-2)
            endif
          endif
!
! modify the Legendre function by multipying the jacobian
! to speed up runtime. Also stick in the neumann factor and 
! the 1/sqrt(rad) factor
!
          Legendre_Qmod(ir,iz,ikr,ikz,im)=&
               Legendre_Q(im)*neumann_factor_eps(im)*jac/sqrt(rad(ikr))
!
        enddo
! 
! Finished grid integration of the Legendre functions
!
        enddo;enddo
        enddo;enddo
!
! Now the co-sines in the azimuthal direction
!
        if (nprocy /= 1) then
          call get_serial_array(tht,tht_serial,'y')
        else
          tht_serial(1:ny)=tht(1:ny)
        endif
!
        do ith=1,nth;do ikt=1,nthgrid
          do im=0,mmax
            fourier_cosine_terms(ith,ikt,im)=cos(im*(tht(ith)-tht_serial(ikt)))
          enddo
        enddo;enddo
!       
    endsubroutine calculate_cross_legendre_functions
!***********************************************************************
    subroutine get_serial_array(array,array_serial,var)
!
      use Mpicomm
!
      real, dimension(:) :: array
      real, dimension(:) :: array_serial
      real, dimension(:), allocatable :: array_proc
      
      integer :: ido,iup,j,nk,nkgrid,nprock,jy,jz
      character :: var
!
      if (var=='y') then 
        nk=ny ; nkgrid=nygrid ; nprock=nprocy
      else if(var=='z') then
        nk=nz ; nkgrid=nzgrid ; nprock=nprocz
      else
        print*,'var=',var
        call stop_it("you can only call it for var='y' or 'z'")
      endif
!
      allocate(array_proc(nk))
!
      if (lmpicomm) then
!
! All processors send its array to the root processor
!
        if (.not.lroot) then
          call mpisend_real(array,nk,root,111)
        else
!
          array_proc=array
!
! The root processor receives all arrays and
! stores them in a single array of dimension nkgrid
!
          do jy=0,nprocy-1
            do jz=0,nprocz-1
              !serial index of the processor
              j=jy+nprocy*jz
              if (j/=0) call mpirecv_real(array_proc,nk,j,111)
!
              if (var=='y') then 
                ido= jy  * nk + 1
                iup=(jy+1)*nk
                array_serial(ido:iup)=array_proc
              endif
!
              if (var=='z') then 
                ido= jz  * nk + 1
                iup=(jz+1)*nk
                array_serial(ido:iup)=array_proc
              endif
!
            enddo
          enddo
        endif
!
! Broadcast the serial array to all processors
!
        call mpibcast_real(array_serial,nkgrid)
!
      else
!
! For serial runs, nk=nkgrid, so just copy the array
!
        array_serial(1:nk)=array(1:nk)
!
      endif
!
    endsubroutine get_serial_array
!***********************************************************************
    subroutine read_poisson_init_pars(unit,iostat)
!
!  Read Poisson init parameters.
!
!  17-oct-2007/anders: coded
!
      integer, intent(in) :: unit
      integer, intent(inout), optional :: iostat
!
      if (present(iostat)) then
        read(unit,NML=poisson_init_pars,ERR=99, IOSTAT=iostat)
      else
        read(unit,NML=poisson_init_pars,ERR=99)
      endif
!
99    return
    endsubroutine read_poisson_init_pars
!***********************************************************************
    subroutine write_poisson_init_pars(unit)
!
!  Write Poisson init parameters.
!
!  17-oct-2007/anders: coded
!
      integer, intent(in) :: unit
!
      write(unit,NML=poisson_init_pars)
!
    endsubroutine write_poisson_init_pars
!***********************************************************************
    subroutine read_poisson_run_pars(unit,iostat)
!
!  Read Poisson run parameters.
!
!  17-oct-2007/anders: coded
!
      integer, intent(in) :: unit
      integer, intent(inout), optional :: iostat
!
      if (present(iostat)) then
        read(unit,NML=poisson_run_pars,ERR=99, IOSTAT=iostat)
      else
        read(unit,NML=poisson_run_pars,ERR=99)
      endif
!
99    return
    endsubroutine read_Poisson_run_pars
!***********************************************************************
    subroutine write_poisson_run_pars(unit)
!
!  Write Poisson run parameters.
!
!  17-oct-2007/anders: coded
!
      integer, intent(in) :: unit
!
      write(unit,NML=poisson_run_pars)
!
    endsubroutine write_poisson_run_pars
!***********************************************************************
endmodule Poisson
