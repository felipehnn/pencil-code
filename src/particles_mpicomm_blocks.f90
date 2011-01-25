! $Id$
!
!  This module deals with communication of particles between processors.
!
!  This version is for block domain decomposition of particles. See
!  particles_map_blocks.f90 for documentation.
!
module Particles_mpicomm
!
  use Cdata
  use Messages
  use Mpicomm
  use Particles_cdata
  use Sub, only: keep_compiler_quiet
!
  implicit none
!
  include 'particles_mpicomm.h'
!
  integer, parameter :: nxb=nxgrid/nbrickx,nyb=nygrid/nbricky,nzb=nzgrid/nbrickz
  integer, parameter :: nbx=nbrickx/nprocx,nby=nbricky/nprocy,nbz=nbrickz/nprocz
  integer, parameter :: nbricks=nbx*nby*nbz
  integer, parameter :: nghostb=1
  integer, parameter :: mxb=nxb+2*nghostb,myb=nyb+2*nghostb,mzb=nzb+2*nghostb
  integer, parameter :: l1b=nghostb+1,l2b=l1b+nxb-1
  integer, parameter :: m1b=nghostb+1,m2b=m1b+nyb-1
  integer, parameter :: n1b=nghostb+1,n2b=n1b+nzb-1
  integer :: nbrick_foster, nproc_parent, nproc_foster, nblock_loc
  integer, dimension (0:nblockmax-1) :: k1_iblock, k2_iblock, npar_iblock
  real, dimension (mxb,0:nbricks-1) :: xbrick
  real, dimension (myb,0:nbricks-1) :: ybrick
  real, dimension (mzb,0:nbricks-1) :: zbrick
  real, dimension (mxb,0:nblockmax-1) :: xb
  real, dimension (myb,0:nblockmax-1) :: yb
  real, dimension (mzb,0:nblockmax-1) :: zb
!
  real, dimension (mxb,myb,mzb,mvar+maux,0:nblockmax-1) :: fb
  real, dimension (mxb,myb,mzb,mvar,0:nblockmax-1) :: dfb
!
  integer, dimension (mpar_loc) :: inearblock
  integer, dimension (0:nblockmax-1) :: ibrick_parent_block, iproc_parent_block
  integer, dimension (0:nbricks-1) :: iproc_foster_brick
  integer, dimension (ncpus) :: iproc_parent_list, iproc_foster_list
!
  real :: xref_par=0.0, yref_par=0.0, zref_par=0.0
  integer :: it1_loadbalance=100
  logical :: lfill_blocks_density=.false., lfill_blocks_velocity=.false.
  logical :: lfill_blocks_gpotself=.false., lfill_bricks_velocity=.false.
  logical :: lreblock_particles_run=.false.
!
  include 'mpif.h'
!
  contains
!***********************************************************************
    subroutine initialize_particles_mpicomm(f,lstarting)
!
!  Perform any post-parameter-read initialization i.e. calculate derived
!  parameters.
!
!  31-oct-09/anders: coded
!
      real, dimension (mx,my,mz,mfarray) :: f
      logical :: lstarting
!
      integer :: iblock, ibrick
!
      intent (in) :: f, lstarting
!
!  Check consistency of brick partition.
!
      if (mod(nbrickx,nprocx)/=0) then
        if (lroot) print*, 'initialize_particles_mpicomm: nbrickx must be ' // &
            'an integer multiple of nprocx'
        if (lroot) print*, 'initialize_particles_mpicomm: nbrickx, nprocx=', &
            nbrickx, nprocx
        call fatal_error_local('initialize_particles_mpicomm','')
      endif
      if (mod(nbricky,nprocy)/=0) then
        if (lroot) print*, 'initialize_particles_mpicomm: nbricky must be ' // &
            'an integer multiple of nprocy'
        if (lroot) print*, 'initialize_particles_mpicomm: nbricky, nprocy=', &
            nbricky, nprocy
        call fatal_error_local('initialize_particles_mpicomm','')
      endif
      if (mod(nbrickz,nprocz)/=0) then
        if (lroot) print*, 'initialize_particles_mpicomm: nbrickz must be ' // &
            'an integer multiple of nprocz'
        if (lroot) print*, 'initialize_particles_mpicomm: nbrickz, nprocz=', &
            nbricky, nprocy
        call fatal_error_local('initialize_particles_mpicomm','')
      endif
      call fatal_error_local_collect()
      if (mod(nxgrid,nbrickx)/=0) then
        if (lroot) print*, 'initialize_particles_mpicomm: nxgrid must be ' // &
            'an integer multiple of nbrickx'
        if (lroot) print*, 'initialize_particles_mpicomm: nbrickx, nxgrid=', &
            nbrickx, nxgrid
        call fatal_error_local('initialize_particles_mpicomm','')
      endif
      if (mod(nygrid,nbricky)/=0) then
        if (lroot) print*, 'initialize_particles_mpicomm: nygrid must be ' // &
            'an integer multiple of nbricky'
        if (lroot) print*, 'initialize_particles_mpicomm: nbricky, nygrid=', &
            nbricky, nygrid
        call fatal_error_local('initialize_particles_mpicomm','')
      endif
      if (mod(nzgrid,nbrickz)/=0) then
        if (lroot) print*, 'initialize_particles_mpicomm: nzgrid must be ' // &
            'an integer multiple of nbrickz'
        if (lroot) print*, 'initialize_particles_mpicomm: nbrickz, nzgrid=', &
            nbrickz, nzgrid
        call fatal_error_local('initialize_particles_mpicomm','')
      endif
      call fatal_error_local_collect()
!
!  Distribute particles evenly among processors to begin with.
!
      if (lstarting) call dist_particles_evenly_procs(ipar)
!
!  Define x, y, and z arrays for bricks.
!
      do ibrick=0,nbricks-1
        ibx=modulo(ibrick,nbx)
        iby=modulo(ibrick/nbx,nby)
        ibz=ibrick/(nbx*nby)
        xbrick(:,ibrick)=x(l1+ibx*nxb-1:l1+(ibx+1)*nxb)
        ybrick(:,ibrick)=y(m1+iby*nyb-1:m1+(iby+1)*nyb)
        zbrick(:,ibrick)=z(n1+ibz*nzb-1:n1+(ibz+1)*nzb)
      enddo
!
      if (lstarting.or.(lreblock_particles_run)) then
!
!  Initially the blocks are set to be all the local processor's bricks.
!
        nblock_loc=nbx*nby*nbz
        if (nblock_loc>nblockmax) then
          if (lroot) then
            print*, 'initialize_particles_mpicomm: allocated too few blocks!'
            print*, 'initialize_particles_mpicomm: nblock_loc, nblockmax=', &
                nblock_loc, nblockmax
            print*, 'initialize_particles_mpicomm: set nblockmax higher in'// &
                ' cparam.local'
          endif
          call fatal_error('initialize_particles_mpicomm','')
        endif
        iproc_parent_block(0:nblock_loc-1)=iproc
        iproc_foster_brick(0:nblock_loc-1)=iproc
        do ibrick=0,nbricks-1
          ibrick_parent_block(ibrick)=ibrick
        enddo
        nproc_parent=1
        iproc_parent_list(1)=iproc
        nproc_foster=1
        iproc_foster_list(1)=iproc
!
        do iblock=0,nblock_loc-1
          ibrick=ibrick_parent_block(iblock)
          xb(:,iblock)=xbrick(:,ibrick)
          yb(:,iblock)=ybrick(:,ibrick)
          zb(:,iblock)=zbrick(:,ibrick)
        enddo
      else
!
!  Read block domain decomposition from file.
!
        call input_blocks(trim(directory_snap)//'/blocks.dat')
      endif
!
!  For placing particles in blocks the CPUs need a common reference point that
!  is not affected by round off errors or representation noise.
!
      if (lroot) then
        xref_par=x(l1)
        yref_par=y(m1)
        zref_par=z(n1)
      endif
      call mpibcast_real(xref_par,1)
      call mpibcast_real(yref_par,1)
      call mpibcast_real(zref_par,1)
!
      call keep_compiler_quiet(f)
!
    endsubroutine initialize_particles_mpicomm
!***********************************************************************
    subroutine dist_particles_evenly_procs(ipar)
!
!  Distribute particles evenly among processors.
!
!  05-jan-05/anders: coded
!
      use Mpicomm,  only: mpibcast_int
!
      integer, dimension (mpar_loc) :: ipar
!
      integer :: i, k, jspec, npar_per_species, npar_rest, icycle, iproc_rec
      integer :: npar_per_species_missed
      integer, dimension (0:ncpus-1) :: ipar1, ipar2
      integer, dimension (0:ncpus-1) :: npar_loc_array, npar_rest_array
!
      intent (inout) :: ipar
!
!  Set index interval of particles that belong to the local processor.
!
      if (lparticles_nbody.and.(npar==nspar)) then
        if (lroot) then
          npar_loc=npar
          !also needs to initialize ipar(k)
          do k=1,nspar
            ipar(k)=k
            ipar_nbody(k)=k
          enddo
        endif
        call mpibcast_int(ipar_nbody,nspar)
      else if (linsert_particles_continuously) then
        npar_loc=0
        ipar=0
      else
!
!  Place particles evenly on all processors. Some processors may get an extra
!  particle if the particle number is not divisible by the number of processors.
!
        npar_loc =npar/ncpus
        npar_rest=npar-npar_loc*ncpus
        do i=0,ncpus-1
          if (i<npar_rest) then
            npar_loc_array(i)=npar_loc+1
          else
            npar_loc_array(i)=npar_loc
          endif
        enddo
        npar_loc=npar_loc_array(iproc)
        if (lroot) print*, 'dist_particles_evenly_procs: npar_loc_array     =',&
            npar_loc_array
!
!  If there are zero particles on a processor, set ipar1 and ipar2 to zero.
!
        if (npar_species==1) then
          do i=0,ncpus-1
            if (npar_loc_array(i)==0) then
              ipar1(i)=0
              ipar2(i)=0
            else
              if (i==0) then
                ipar1(i)=1
              else
                ipar1(i)=maxval(ipar2(0:i-1))+1
              endif
              ipar2(i)=ipar1(i) + npar_loc_array(i) - 1
            endif
          enddo
!
          if (lroot) then
            print*, 'dist_particles_evenly_procs: ipar1 =', ipar1
            print*, 'dist_particles_evenly_procs: ipar2 =', ipar2
          endif
!
!  Fill in particle index between ipar1 and ipar2.
!
          do k=1,npar_loc
            ipar(k)=k-1+ipar1(iproc)
          enddo
        else
!
!  Must have same number of particles in each species.
!
          if (mod(npar,npar_species)/=0) then
            if (lroot) then
              print*, 'dist_particles_evenly_procs: npar_species '// &
                  'must be a whole multiple of npar!'
              print*, 'npar_species, npar=', npar_species, npar
            endif
            call fatal_error('dist_particles_evenly_procs','')
          endif
!
!  Distribute particle species evenly among processors.
!        
          npar_per_species=npar/npar_species
!
          do jspec=1,npar_species
            do k=1,npar_per_species/ncpus
              ipar(k+npar_per_species/ncpus*(jspec-1))= &
                 k+npar_per_species*(jspec-1)+iproc*(npar_per_species/ncpus)
            enddo
          enddo
!
!  Calculate right index for each species.
!
          ipar_fence_species(1)=npar_per_species
          ipar_fence_species(npar_species)=npar
          ipar_fence_species(1)=npar_per_species
          ipar_fence_species(npar_species)=npar
!
          do jspec=2,npar_species-1
            ipar_fence_species(jspec)= &
                ipar_fence_species(jspec-1)+npar_per_species
          enddo
!
          if (lroot) then
            print*, 'dist_particles_evenly_procs: npar_per_species   =', &
                npar_per_species
            print*, 'dist_particles_evenly_procs: ipar_fence_species =', &
                ipar_fence_species
          endif
!
!  It is not always possible to have the same number of particles of each
!  species at each processor. In that case we place the remaining particles
!  by hand in order of increasing processor number.
!
          npar_rest_array=npar_loc_array-npar_per_species/ncpus*npar_species
!
          if (lroot .and. (minval(npar_rest_array)/=0)) &
              print*, 'dist_particles_evenly_procs: npar_rest_array    =', &
              npar_rest_array
!
          npar_per_species_missed = &
              npar_per_species-ncpus*(npar_per_species/ncpus)
          icycle   =1
          iproc_rec=0
          do k=1,npar_per_species_missed*npar_species
            jspec=(k-1)/npar_per_species_missed+1
            if (iproc==iproc_rec) &
                ipar(npar_loc-npar_rest_array(iproc_rec)+icycle)= &
                ipar_fence_species(jspec)-jspec*npar_per_species_missed+k
            if (lroot) print*, 'dist_particles_evenly_procs: placed ', &
                'particle', ipar_fence_species(jspec)- &
                jspec*npar_per_species_missed+k, &
                ' on proc', iproc_rec, ' in species', jspec
            iproc_rec=iproc_rec+1
            if (iproc_rec==ncpus) then
              iproc_rec=0
              icycle=icycle+1
            endif
          enddo
        endif
!
      endif
!
    endsubroutine dist_particles_evenly_procs
!***********************************************************************
    subroutine migrate_particles(fp,ipar,dfp,linsert)
!
!  Migrate particles between processors.
!
!  Migration is divided into three steps for block domain decomposition:
!
!    1. Particles that are no longer in any blocks adopted by the
!       considered processor are migrated to their parent processor.
!
!    2. The parent processor either keeps the particle, if it is really
!       the parent, or migrates the particle to the actual parent. The
!       actual parent may differ from the registred parent if the particle
!       has moved away from the latter.
!
!    3. The parent processor either keeps the particle, if the particle
!       is in one of its blocks, or migrates the particle to the foster
!       parent.
!
!  The three-step division is necessary to have directed communication
!  between processors, because it is impractical at high processor
!  numbers to allow all processors to exchange particles.
!
!  31-oct-09/anders: coded
!
      real, dimension (mpar_loc,mpvar) :: fp
      integer, dimension (mpar_loc) :: ipar
      real, dimension (mpar_loc,mpvar), optional :: dfp
      logical, optional :: linsert
!
!  Migrate particles that are no longer in any block maintained by the
!  processor.
!
      if (ip<10) call report_missing_particles('migrate_particles (0)')
      call migrate_particles_block_to_proc(fp,ipar,dfp)
      if (ip<10) call report_missing_particles('migrate_particles (1)')
!
!  Migrate particles to actual parent, in case that differs from previous
!  parent.
!
      call migrate_particles_proc_to_proc(fp,ipar,dfp)
      if (ip<10) call report_missing_particles('migrate_particles (2)')
!
!  Migrate particles from parent to foster parents.
!
      call migrate_particles_proc_to_block(fp,ipar,dfp)
      if (ip<10) call report_missing_particles('migrate_particles (3)')
!
      if (present(linsert)) call keep_compiler_quiet(linsert)
!
    endsubroutine migrate_particles
!***********************************************************************
    subroutine migrate_particles_block_to_proc(fp,ipar,dfp)
!
!  Migrate particles that are no longer in an adopted block to the
!  (previous) parent processor. The parent processor then either keeps
!  the particle or sends it to its new parent.
!
!  28-oct-09/anders: coded
!
      use Diagnostics, only: max_name
!
      real, dimension (mpar_loc,mpvar) :: fp
      integer, dimension (mpar_loc) :: ipar
      real, dimension (mpar_loc,mpvar), optional :: dfp
!
      real, dimension (npar_mig,mpvar) :: fp_mig, dfp_mig
      real, save :: dx1, dy1, dz1
      integer, dimension (npar_mig) :: ipar_mig, iproc_rec_array
      integer, dimension (npar_mig) :: isort_array
      integer, dimension (0:ncpus-1) :: nmig_leave, nmig_enter
      integer, dimension (0:ncpus-1) :: ileave_low, ileave_high
      integer, dimension (0:ncpus-1) :: iproc_rec_count
      integer, dimension (0:nblockmax-1) :: ibrick_global_arr
      integer :: ix0, iy0, iz0, ipx0, ipy0, ipz0, ibx0, iby0, ibz0
      integer :: ibrick_rec, iproc_rec, nmig_enter_proc, npar_loc_start
      integer :: i, j, k, iblock, nmig_enter_proc_tot
      integer :: ibrick_global_rec, ibrick_global_rec_previous
      integer :: iblockl, iblocku, iblockm
      integer :: nmig_leave_total, ileave_high_max
      integer :: itag_nmig=500, itag_ipar=510, itag_fp=520, itag_dfp=530
      logical :: lredo, lredo_all, lmigrate, lmigrate_previous
      logical :: lreblocking
      logical, save :: lfirstcall=.true.
!
      intent (inout) :: fp, ipar, dfp
!
      if (lfirstcall) then
        dx1=1/dx; dy1=1/dy; dz1=1/dz
        lfirstcall=.false.
      endif
!
      lreblocking=lreblock_particles_run.and.it==1.and.itsub==0
!
      ibrick_global_arr(0:nblock_loc-1)= &
          iproc_parent_block(0:nblock_loc-1)*nbricks+ &
          ibrick_parent_block(0:nblock_loc-1)
      ibrick_global_rec_previous=-1
      lmigrate_previous=.false.
!
      nmig_enter_proc_tot=0
!
!  Possible to iterate until all particles have migrated.
!
      lredo=.false.; lredo_all=.true.
      npar_loc_start=npar_loc
!
      do while (lredo_all)
        lredo=.false.
!
        nmig_leave=0
        nmig_leave_total=0
        nmig_enter=0
!
        do k=npar_loc_start,1,-1
!
!  Calculate processor and brick index of particle.
!
          ix0=l1b; iy0=m1b; iz0=n1b; ibx0=0; iby0=0; ibz0=0
          ipx0=0; ipy0=0; ipz0=0
!
          if (nxgrid/=1) then  !  Find processor and brick x-coordinate
            ix0=nint((fp(k,ixp)-xref_par)*dx1)+1
            ipx0=(ix0-1)/nx
            ix0=ix0-ipx0*nx
            ibx0=(ix0-1)/nxb
          endif
!
          if (nygrid/=1) then  !  Find processor and brick y-coordinate
            iy0=nint((fp(k,iyp)-yref_par)*dy1)+1
            ipy0=(iy0-1)/ny
            iy0=iy0-ipy0*ny
            iby0=(iy0-1)/nyb
          endif
!
          if (nzgrid/=1) then  !  Find processor and brick z-coordinate
            iz0=nint((fp(k,izp)-zref_par)*dz1)+1
            ipz0=(iz0-1)/nz
            iz0=iz0-ipz0*nz
            ibz0=(iz0-1)/nzb
          endif
!
!  Calculate processor and brick index of particle.
!
          ibrick_rec=ibx0+iby0*nbx+ibz0*nbx*nby
          iproc_rec =ipx0+ipy0*nprocx+ipz0*nprocx*nprocy
!
!  Find out whether particle has left the blocks adopted by this processor.
!
          ibrick_global_rec=iproc_rec*nbricks+ibrick_rec
          if (ibrick_global_rec==ibrick_global_rec_previous) then
            lmigrate=lmigrate_previous
          else
            lmigrate=.true.
            iblockl=0; iblocku=nblock_loc-1
            do while (abs(iblocku-iblockl)>1)
              iblockm=(iblockl+iblocku)/2
              if (ibrick_global_rec>ibrick_global_arr(iblockm)) then
                iblockl=iblockm
              else
                iblocku=iblockm
              endif
            enddo
            if (ibrick_global_rec==ibrick_global_arr(iblockl) .or. &
                ibrick_global_rec==ibrick_global_arr(iblocku)) then
              lmigrate=.false.
            endif
          endif
          lmigrate_previous=lmigrate
          ibrick_global_rec_previous=ibrick_global_rec
!
!  Migrate particle to parent, if it is no longer in any block at the current
!  processor. The parent will then either keep the particle or send it to
!  a new parent.
!
          if (lmigrate.and.(iproc/=iproc_parent_block(inearblock(k)))) then
            iproc_rec=iproc_parent_block(inearblock(k))
            if (ip<=7) print '(a,i8,a,i4,a,i4)', &
                'migrate_particles_btop: Particle ', ipar(k), &
                ' moves out of proc ', iproc, ' and into proc ', iproc_rec
            if (ip<=7) then  ! Quick reality check
              if (iproc_rec==iproc) then
                print '(a,i8,a,i3,a,i4)', &
                    'migrate_particles_btop: Particle ', ipar(k), &
                    ' moves out of proc ', iproc, ' and into proc ', iproc_rec
                print*, 'migrate_particles_btop: iproc_rec=iproc - '// &
                    'this is ridiculous'
                print*, 'migrate_particles_btop: ibrick_rec, iproc_rec, '// &
                    'inearblock=', ibrick_rec, iproc_rec, inearblock(k)
                print*, 'migrate_particles_btop: '// &
                    'ipx0, ipy0, ipz0=', ipx0, ipy0, ipz0
                print*, 'migrate_particles_btop: '// &
                    'lmigrate, lmigrate_previous=', lmigrate, lmigrate_previous
                print*, 'migrate_particles_btop: '// &
                    'ibrick_rec, ibrick_global_rec=', &
                    ibrick_rec, ibrick_global_rec
                print*, 'migrate_particles_btop: iblockl, iblocku=', &
                    iblockl, iblocku
                print*, 'migrate_particles_btop: iproc_parent_block=', &
                    iproc_parent_block(0:nblock_loc-1)
                print*, 'migrate_particles_btop: ibrick_parent_block=', &
                    ibrick_parent_block(0:nblock_loc-1)
              endif
            endif
!
!  Copy migrating particle to the end of the fp array.
!
            nmig_leave(iproc_rec)=nmig_leave(iproc_rec)+1
            nmig_leave_total     =nmig_leave_total     +1
            if (sum(nmig_leave)>npar_mig) then
              if (.not.(lstart.or.lreblocking)) then
                print '(a,i3,a,i3,a)', &
                    'migrate_particles_btop: too many particles migrating '// &
                    'from proc ', iproc
                print*, '  (npar_mig,nmig,npar_loc,k=', &
                    npar_mig, sum(nmig_leave), npar_loc, k, ')'
              endif
              if (lstart.or.lmigration_redo) then
                if (.not.(lstart.or.lreblocking)) then
                  print*, '  Going to do one more migration iteration!'
                  print*, '  (this may be time consuming - '// &
                      'consider setting npar_mig'
                  print*, '  higher in cparam.local)'
                endif
                nmig_leave(iproc_rec)=nmig_leave(iproc_rec)-1
                nmig_leave_total     =nmig_leave_total     -1
                lredo=.true.
                exit
              else
                call fatal_error('migrate_particles_btop','')
              endif
            endif
            fp_mig(nmig_leave_total,:)=fp(k,:)
            if (present(dfp)) dfp_mig(nmig_leave_total,:)=dfp(k,:)
            ipar_mig(nmig_leave_total)=ipar(k)
            iproc_rec_array(nmig_leave_total)=iproc_rec
!
!  Move the particle with the highest index number to the empty spot left by
!  the migrating particle.
!
            fp(k,:)=fp(npar_loc,:)
            if (present(dfp)) dfp(k,:)=dfp(npar_loc,:)
            ipar(k)=ipar(npar_loc)
!
!  Reduce the number of particles by one.
!
            npar_loc=npar_loc-1
          endif
        enddo
        npar_loc_start=k
!
!  Print out information about number of migrating particles.
!
        if (ip<=8) print*, 'migrate_particles_btop: iproc, nmigrate = ', &
            iproc, sum(nmig_leave)
!
!  Diagnostic about number of migrating particles.
!  WARNING: in time-steps where snapshots are written, this diagnostic
!  parameter will be zero (quite confusing)!
!
        if (ldiagnos.and.(idiag_nmigmax/=0)) &
            call max_name(sum(nmig_leave),idiag_nmigmax)
!
!  Share information about number of migrating particles. We only communicate
!  particles between processors that are either parents or foster parents
!  of each other's particles.
!
        do i=1,nproc_parent
          if (iproc_parent_list(i)/=iproc) &
              call mpisend_int(nmig_leave(iproc_parent_list(i)),1, &
              iproc_parent_list(i),itag_nmig+iproc)
        enddo
        do i=1,nproc_foster
          if (iproc_foster_list(i)/=iproc) &
              call mpirecv_int(nmig_enter(iproc_foster_list(i)),1, &
              iproc_foster_list(i),itag_nmig+iproc_foster_list(i))
        enddo
!
!  Check that there is room for the new particles at each processor.
!
        nmig_enter_proc=sum(nmig_enter)
        nmig_enter_proc_tot=nmig_enter_proc_tot+nmig_enter_proc
        if (npar_loc+nmig_enter_proc>mpar_loc) then
          print*, 'migrate_particles_btop: ', &
              'too many particles want to be at proc', iproc
          print*, 'migrate_particles_btop: npar_loc, mpar_loc, nmig=', &
              npar_loc, mpar_loc, nmig_enter_proc
          call fatal_error_local('migrate_particles_btop','')
        endif
        call fatal_error_local_collect()
!
!  Sort array of migrating particle in order of receiving processor.
!
        if (nmig_leave_total>=1) then
          ileave_high_max=0
          do i=0,ncpus-1
            if (nmig_leave(i)>=1) then
              ileave_low(i)  =ileave_high_max+1
              ileave_high(i) =ileave_low(i)+nmig_leave(i)-1
              ileave_high_max=ileave_high_max+nmig_leave(i)
            else
              ileave_low(i) =0
              ileave_high(i)=0
            endif
          enddo
          iproc_rec_count=0
          do k=1,nmig_leave_total
            isort_array(ileave_low(iproc_rec_array(k))+iproc_rec_count(iproc_rec_array(k)))=k
            iproc_rec_count(iproc_rec_array(k))= &
                iproc_rec_count(iproc_rec_array(k))+1
          enddo
          ipar_mig(1:nmig_leave_total)= &
              ipar_mig(isort_array(1:nmig_leave_total))
          fp_mig(1:nmig_leave_total,:)= &
              fp_mig(isort_array(1:nmig_leave_total),:)
          if (present(dfp)) dfp_mig(1:nmig_leave_total,:)= &
              dfp_mig(isort_array(1:nmig_leave_total),:)
        endif
!
!  Set to receive.
!
        do i=0,ncpus-1
          if (iproc/=i .and. nmig_enter(i)/=0) then
            call mpirecv_real(fp(npar_loc+1:npar_loc+nmig_enter(i),:), &
                (/nmig_enter(i),mpvar/),i,itag_fp)
            call mpirecv_int(ipar(npar_loc+1:npar_loc+nmig_enter(i)), &
                nmig_enter(i),i,itag_ipar)
            if (present(dfp)) &
                call mpirecv_real(dfp(npar_loc+1:npar_loc+nmig_enter(i),:), &
                (/nmig_enter(i),mpvar/),i,itag_dfp)
            if (ip<=6) then
              print*, 'migrate_particles_btop: iproc, iproc_send=', iproc, i
              print*, 'migrate_particles_btop: received fp=', &
                  fp(npar_loc+1:npar_loc+nmig_enter(i),:)
              print*, 'migrate_particles_btop: received ipar=', &
                  ipar(npar_loc+1:npar_loc+nmig_enter(i))
              if (present(dfp)) &
                  print*, 'migrate_particles_btop: received dfp=',&
                  dfp(npar_loc+1:npar_loc+nmig_enter(i),:)
            endif
!
            npar_loc=npar_loc+nmig_enter(i)
            if (npar_loc>mpar_loc) then
              print*, 'migrate_particles_btop: '// &
                  'too many particles at proc', iproc
              print*, 'migrate_particles_btop: npar_loc, mpar_loc=', &
                  npar_loc, mpar_loc
              call fatal_error('migrate_particles_btop','')
            endif
          endif
!
!  Directed send.
!
          if (iproc==i) then
            do j=0,ncpus-1
              if (iproc/=j .and. nmig_leave(j)/=0) then
                call mpisend_real(fp_mig(ileave_low(j):ileave_high(j),:), &
                    (/nmig_leave(j),mpvar/),j,itag_fp)
                call mpisend_int(ipar_mig(ileave_low(j):ileave_high(j)), &
                    nmig_leave(j),j,itag_ipar)
                if (present(dfp)) &
                    call mpisend_real(dfp_mig(ileave_low(j):ileave_high(j),:), &
                    (/nmig_leave(j),mpvar/),j,itag_dfp)
                if (ip<=6) then
                  print*, 'migrate_particles_btop: iproc, iproc_rec=', iproc, j
                  print*, 'migrate_particles_btop: sent fp=', &
                      fp_mig(ileave_low(j):ileave_high(j),:)
                  print*, 'migrate_particles_btop: sent ipar=', &
                      ipar_mig(ileave_low(j):ileave_high(j))
                  if (present(dfp)) &
                      print*, 'migrate_particles_btop: sent dfp=', &
                      dfp_mig(ileave_low(j):ileave_high(j),:)
                endif
              endif
            enddo
          endif
        enddo
!
!  Sum up processors that have not had place to let all migrating particles go.
!
        if (lstart.or.lmigration_redo) then   !  5-10% slowdown of code
          call mpireduce_or(lredo, lredo_all)
          call mpibcast_logical(lredo_all, 1)
        else
          lredo_all=.false.
        endif
!
!  If sum is not zero, then the while loop will be executed once more.
!
      enddo
!
    endsubroutine migrate_particles_block_to_proc
!***********************************************************************
    subroutine migrate_particles_proc_to_proc(fp,ipar,dfp)
!
!  Migrate particles that are no longer in their previous parent processors
!  to their new parent processors.
!
!  28-oct-09/anders: coded
!
      use Diagnostics, only: max_name
!
      real, dimension (mpar_loc,mpvar) :: fp
      integer, dimension (mpar_loc) :: ipar
      real, dimension (mpar_loc,mpvar), optional :: dfp
!
      real, dimension (npar_mig,mpvar) :: fp_mig, dfp_mig
      real, save :: dx1, dy1, dz1
      integer, dimension (npar_mig) :: ipar_mig, iproc_rec_array
      integer, dimension (npar_mig) :: isort_array
      integer, dimension (0:ncpus-1) :: nmig_leave, nmig_enter
      integer, dimension (0:ncpus-1) :: ileave_low, ileave_high
      integer, dimension (0:ncpus-1) :: iproc_rec_count
      integer, dimension (26), save :: iproc_comm=-1
      integer, save :: nproc_comm=0
      integer :: dipx, dipy, dipz, iblock, ibrick_rec, npar_loc_start
      integer :: ix0, iy0, iz0, ipx0, ipy0, ipz0, ibx0, iby0, ibz0
      integer :: i, j, k, iproc_rec, ipx_rec, ipy_rec, ipz_rec
      integer :: nmig_leave_total, ileave_high_max
      logical :: lredo, lredo_all
      integer :: itag_nmig=540, itag_ipar=550, itag_fp=560, itag_dfp=570
      logical :: lmigrate, lreblocking
      logical, save :: lfirstcall=.true.
!
      intent (inout) :: fp, ipar, dfp
!
      if (lfirstcall) then
        dx1=1/dx; dy1=1/dy; dz1=1/dz
        lfirstcall=.false.
      endif
!
      lreblocking=lreblock_particles_run.and.it==1.and.itsub==0
!
!  Create list of processors that we allow migration to and from.
!
      if (lshear .or. (it==1 .and. lfirst)) then
        iproc_comm=-1; nproc_comm=0
        do dipx=-1,1; do dipy=-1,1; do dipz=-1,1
          ipx_rec=ipx+dipx
          ipy_rec=ipy+dipy
          if (lshear) then
            if (ipx_rec<0) &
                ipy_rec=ipy_rec-ceiling(deltay/Lxyz_loc(2)-0.5)
            if (ipx_rec>nprocx-1) &
                ipy_rec=ipy_rec+ceiling(deltay/Lxyz_loc(2)-0.5)
          endif
          ipz_rec=ipz+dipz
          do while (ipx_rec<0);        ipx_rec=ipx_rec+nprocx; enddo
          do while (ipx_rec>nprocx-1); ipx_rec=ipx_rec-nprocx; enddo
          do while (ipy_rec<0);        ipy_rec=ipy_rec+nprocy; enddo
          do while (ipy_rec>nprocy-1); ipy_rec=ipy_rec-nprocy; enddo
          do while (ipz_rec<0);        ipz_rec=ipz_rec+nprocz; enddo
          do while (ipz_rec>nprocz-1); ipz_rec=ipz_rec-nprocz; enddo
          iproc_rec=ipx_rec+ipy_rec*nprocx+ipz_rec*nprocx*nprocy
          if (iproc_rec/=iproc) then
            if (nproc_comm==0) then
              nproc_comm=nproc_comm+1
              iproc_comm(nproc_comm)=iproc_rec
            elseif ( (.not.any(iproc_rec==iproc_comm(1:nproc_comm))) .and. &
                 (iproc_rec/=iproc) ) then
              nproc_comm=nproc_comm+1
              iproc_comm(nproc_comm)=iproc_rec
            endif
          endif
        enddo; enddo; enddo
      endif
!
!  Possible to iterate until all particles have migrated.
!
      lredo=.false.; lredo_all=.true.
      npar_loc_start=npar_loc
!
      do while (lredo_all)
        lredo=.false.
!
!  Find out which particles are not in the local processor's xyz-interval.
!  Need to use special definition of processor boundaries for migration since
!  the physical processor boundaries may be closer to a ghost point than to a
!  physical grid point. Thus we need to define the boundary as the average
!  coordinate value of the last grid point and the first ghost point.
!
        nmig_leave=0
        nmig_leave_total=0
        nmig_enter=0
!
        do k=npar_loc_start,1,-1
!
!  Calculate processor and brick index of particle.
!
          ix0=nghostb+1; iy0=nghostb+1; iz0=nghostb+1; ibx0=0; iby0=0; ibz0=0
          ipx0=0; ipy0=0; ipz0=0
!
          if (nxgrid/=1) then  !  Find processor and brick x-coordinate
            ix0=nint((fp(k,ixp)-xref_par)*dx1)+1
            ipx0=(ix0-1)/nx
            ix0=ix0-ipx0*nx
            ibx0=(ix0-1)/nxb
          endif
!
          if (nygrid/=1) then  !  Find processor and brick y-coordinate
            iy0=nint((fp(k,iyp)-yref_par)*dy1)+1
            ipy0=(iy0-1)/ny
            iy0=iy0-ipy0*ny
            iby0=(iy0-1)/nyb
          endif
!
          if (nzgrid/=1) then  !  Find processor and brick z-coordinate
            iz0=nint((fp(k,izp)-zref_par)*dz1)+1
            ipz0=(iz0-1)/nz
            iz0=iz0-ipz0*nz
            ibz0=(iz0-1)/nzb
          endif
!
!  Calculate processor and brick index of particle.
!
          ibrick_rec=ibx0+iby0*nbx+ibz0*nbx*nby
          iproc_rec =ipx0+ipy0*nprocx+ipz0*nprocx*nprocy
!
!  Find out whether particle is in any of the blocks adopted by this processor.
!
          lmigrate=.false.
          if (iproc_rec/=iproc) then
            lmigrate=.true.
            do iblock=0,nblock_loc-1
              if (iproc_parent_block(iblock)==iproc_rec .and. &
                  ibrick_parent_block(iblock)==ibrick_rec) then
                lmigrate=.false.
                exit
              endif
            enddo
          endif
!
!  Migrate particle if a) it is not in any blocks adopted by this processor
!  and b) its parent processor is not this processor.
!
          if (lmigrate) then
            if (ip<=7) print '(a,i8,a,i4,a,i4)', &
                'migrate_particles_proc_to_proc: Particle ', ipar(k), &
                ' moves out of proc ', iproc, &
                ' and into proc ', iproc_rec
            if (ip<=7) then  !  Quick reality check
              if (.not.any(iproc_rec==iproc_comm(1:nproc_comm))) then
                print*, 'migrate_particles_ptop: trying to migrate to '// &
                    'processor that is not in comm list'
                print '(a,i8,a,i4,a,i4)', &
                  'migrate_particles_ptop: Particle ', ipar(k), &
                  ' moves out of proc ', iproc, &
                  ' and into proc ', iproc_rec
                print*, 'migrate_particles_ptop: iproc, iproc_rec=', &
                    iproc, iproc_rec
                print*, 'migrate_particles_ptop: ipx , ipy , ipz =', &
                    ipx, ipy, ipz
                print*, 'migrate_particles_ptop: ipx0, ipy0, ipz0=', &
                    ipx0, ipy0, ipz0
                print*, 'migrate_particles_ptop: it, itsub, t, deltay=', &
                    it, itsub, t, deltay
                print*, 'migrate_particles_ptop: fp=', fp(k,:)
                print*, 'migrate_particles_ptop: iproc_comm=', &
                    iproc_comm(1:nproc_comm)
              endif
            endif
            if (iproc_rec>=ncpus .or. iproc_rec<0) then
              call warning('migrate_particles','',iproc)
              print*, 'migrate_particles_ptop: receiving proc does not exist'
              print*, 'migrate_particles_ptop: iproc, iproc_rec=', &
                  iproc, iproc_rec
              print*, 'migrate_particles_ptop: ipar(k), xxp=', &
                  ipar(k), fp(k,ixp:izp)
              print*, 'migrate_particles_ptop: x0_mig, x1_mig=', &
                  procx_bounds(ipx), procx_bounds(ipx+1)
              print*, 'migrate_particles_ptop: y0_mig, y1_mig=', &
                  procy_bounds(ipy), procy_bounds(ipy+1)
              print*, 'migrate_particles_ptop: z0_mig, z1_mig=', &
                  procz_bounds(ipz), procz_bounds(ipz+1)
              call fatal_error_local("","")
            endif
!
!  Copy migrating particle to the end of the fp array.
!
            nmig_leave(iproc_rec)=nmig_leave(iproc_rec)+1
            nmig_leave_total     =nmig_leave_total     +1
            if (sum(nmig_leave)>npar_mig) then
              if (.not.(lstart.or.lreblocking)) then
                print '(a,i3,a,i3,a)', &
                    'migrate_particles_ptop: too many particles migrating '// &
                    'from proc ', iproc
                print*, '  (npar_mig,nmig,npar_loc,k=', &
                    npar_mig, sum(nmig_leave), npar_loc, k, ')'
              endif
              if (lstart.or.lmigration_redo) then
                if (.not.(lstart.or.lreblocking)) then
                  print*, '  Going to do one more migration iteration!'
                  print*, '  (this may be time consuming - '//&
                      'consider setting npar_mig'
                  print*, '  higher in cparam.local)'
                endif
                nmig_leave(iproc_rec)=nmig_leave(iproc_rec)-1
                nmig_leave_total     =nmig_leave_total     -1
                lredo=.true.
                exit
              else
                call fatal_error('migrate_particles_ptop','')
              endif
            endif
            fp_mig(nmig_leave_total,:)=fp(k,:)
            if (present(dfp)) dfp_mig(nmig_leave_total,:)=dfp(k,:)
            ipar_mig(nmig_leave_total)=ipar(k)
            iproc_rec_array(nmig_leave_total)=iproc_rec
!
!  Move the particle with the highest index number to the empty spot left by
!  the migrating particle.
!
            fp(k,:)=fp(npar_loc,:)
            if (present(dfp)) dfp(k,:)=dfp(npar_loc,:)
            ipar(k)=ipar(npar_loc)
!
!  Reduce the number of particles by one.
!
            npar_loc=npar_loc-1
          endif
        enddo
        npar_loc_start=k
!
!  Print out information about number of migrating particles.
!
        if (ip<=8) print*, 'migrate_particles_ptop: iproc, nmigrate = ', &
            iproc, sum(nmig_leave)
!
!  Diagnostic about number of migrating particles.
!  WARNING: in time-steps where snapshots are written, this diagnostic
!  parameter will be zero (quite confusing)!
!
        if (ldiagnos.and.(idiag_nmigmax/=0)) &
            call max_name(sum(nmig_leave),idiag_nmigmax)
!
!  Share information about number of migrating particles. For the initial
!  condition we allow all processors to communicate particles. However, this
!  is extremely slow when the processor number is high (>>100). Thus we only
!  allow communication with surrounding processors during the run.
!
        if (lstart.or.lreblocking) then
          do i=0,ncpus-1
            if (iproc/=i) then
              call mpirecv_int(nmig_enter(i),1,i,itag_nmig)
            else
              do j=0,ncpus-1
                if (iproc/=j) call mpisend_int(nmig_leave(j),1,j,itag_nmig)
              enddo
            endif
          enddo
        else
          do i=1,nproc_comm
            call mpisend_int(nmig_leave(iproc_comm(i)),1,iproc_comm(i),itag_nmig+iproc)
          enddo
          do i=1,nproc_comm
            call mpirecv_int(nmig_enter(iproc_comm(i)),1,iproc_comm(i),itag_nmig+iproc_comm(i))
          enddo
        endif
!
!  Check that there is room for the new particles at each processor.
!
        if (npar_loc+sum(nmig_enter)>mpar_loc) then
          print*, 'migrate_particles_ptop: '// &
              'too many particles want to be at proc', iproc
          print*, 'migrate_particles_ptop: npar_loc, mpar_loc, nmig=', &
              npar_loc, mpar_loc, sum(nmig_enter)
          call fatal_error_local('migrate_particles_ptop','')
        endif
        call fatal_error_local_collect()
!
!  Sort array of migrating particle in order of receiving processor.
!
        if (nmig_leave_total>=1) then
          ileave_high_max=0
          do i=0,ncpus-1
            if (nmig_leave(i)>=1) then
              ileave_low(i)  =ileave_high_max+1
              ileave_high(i) =ileave_low(i)+nmig_leave(i)-1
              ileave_high_max=ileave_high_max+nmig_leave(i)
            else
              ileave_low(i) =0
              ileave_high(i)=0
            endif
          enddo
          iproc_rec_count=0
          do k=1,nmig_leave_total
            isort_array(ileave_low(iproc_rec_array(k))+iproc_rec_count(iproc_rec_array(k)))=k
            iproc_rec_count(iproc_rec_array(k))= &
                iproc_rec_count(iproc_rec_array(k))+1
          enddo
          ipar_mig(1:nmig_leave_total)= &
              ipar_mig(isort_array(1:nmig_leave_total))
          fp_mig(1:nmig_leave_total,:)= &
              fp_mig(isort_array(1:nmig_leave_total),:)
          if (present(dfp)) dfp_mig(1:nmig_leave_total,:)= &
              dfp_mig(isort_array(1:nmig_leave_total),:)
        endif
!
!  Make sure that processors only exchange particles with direct neighbours.
!  Wrong block decomposition can cause an error here - in that case set
!  lreblock_particles_run=T in run.in to create a new block decomposition.
!
        if (.not.(lstart.or.lreblocking)) then
          do i=0,ncpus-1
            if (nmig_enter(i)/=0.or.nmig_leave(i)/=0) then
              if (.not.any(iproc_comm(1:nproc_comm)==i)) then
                print*, 'migrate_particles_ptop: trying to send particles '// &
                    'from proc ', i, ' to proc ', iproc, &
                    ', but those processors are not neighbours!'
                call fatal_error_local('migrate_particles_ptop','')
              endif
            endif
          enddo
          call fatal_error_local_collect()
        endif
!
!  Set to receive.
!
        do i=0,ncpus-1
          if (iproc/=i .and. nmig_enter(i)/=0) then
            call mpirecv_real(fp(npar_loc+1:npar_loc+nmig_enter(i),:), &
                (/nmig_enter(i),mpvar/),i,itag_fp)
            call mpirecv_int(ipar(npar_loc+1:npar_loc+nmig_enter(i)), &
                nmig_enter(i),i,itag_ipar)
            if (present(dfp)) &
                call mpirecv_real(dfp(npar_loc+1:npar_loc+nmig_enter(i),:), &
                (/nmig_enter(i),mpvar/),i,itag_dfp)
            if (ip<=6) then
              print*, 'migrate_particles_ptop: iproc, iproc_send=', iproc, i
              print*, 'migrate_particles_ptop: received fp=', &
                  fp(npar_loc+1:npar_loc+nmig_enter(i),:)
              print*, 'migrate_particles_ptop: received ipar=', &
                  ipar(npar_loc+1:npar_loc+nmig_enter(i))
              if (present(dfp)) &
                  print*, 'migrate_particles_ptop: received dfp=',&
                  dfp(npar_loc+1:npar_loc+nmig_enter(i),:)
            endif
!
!  Check that received particles are really at the right processor.
!
            if (lmigration_real_check) then
              do k=npar_loc+1,npar_loc+nmig_enter(i)
                if ((nxgrid/=1.and.( &
                    fp(k,ixp)< procx_bounds(ipx)     .or. &
                    fp(k,ixp)>=procx_bounds(ipx+1))) .or. &
                    (nygrid/=1.and.( &
                    fp(k,iyp)< procy_bounds(ipy)     .or. &
                    fp(k,iyp)>=procy_bounds(ipy+1))) .or. &
                    (nzgrid/=1.and.( &
                    fp(k,izp)< procz_bounds(ipz)     .or. &
                    fp(k,izp)>=procz_bounds(ipz+1)))) then
                  print*, 'migrate_particles_ptop: received particle '// &
                      'closer to ghost point than to physical grid point!'
                  print*, 'migrate_particles_ptop: '// &
                      'iproc, iproc_rec, it, itsub=', iproc, i, it, itsub
                  print*, 'migrate_particles_ptop: ipar, xxp=', &
                      ipar(k), fp(k,ixp:izp)
                  print*, 'migrate_particles_ptop: x0_mig, x1_mig=', &
                      procx_bounds(ipx), procx_bounds(ipx+1)
                  print*, 'migrate_particles_ptop: y0_mig, y1_mig=', &
                      procy_bounds(ipy), procy_bounds(ipy+1)
                  print*, 'migrate_particles_ptop: z0_mig, z1_mig=', &
                      procz_bounds(ipz), procz_bounds(ipz+1)
                endif
              enddo
            endif
            npar_loc=npar_loc+nmig_enter(i)
            if (npar_loc>mpar_loc) then
              print*, 'migrate_particles_ptop: '// &
                  'too many particles at proc', iproc
              print*, 'migrate_particles_ptop: npar_loc, mpar_loc=', &
                  npar_loc, mpar_loc
              call fatal_error('migrate_particles_ptop','')
            endif
          endif
!
!  Directed send.
!
          if (iproc==i) then
            do j=0,ncpus-1
              if (iproc/=j .and. nmig_leave(j)/=0) then
                call mpisend_real(fp_mig(ileave_low(j):ileave_high(j),:), &
                    (/nmig_leave(j),mpvar/),j,itag_fp)
                call mpisend_int(ipar_mig(ileave_low(j):ileave_high(j)), &
                    nmig_leave(j),j,itag_ipar)
                if (present(dfp)) &
                    call mpisend_real(dfp_mig(ileave_low(j):ileave_high(j),:), &
                    (/nmig_leave(j),mpvar/),j,itag_dfp)
                if (ip<=6) then
                  print*, 'migrate_particles_ptop: iproc, iproc_rec=', iproc, j
                  print*, 'migrate_particles_ptop: sent fp=', &
                      fp_mig(ileave_low(j):ileave_high(j),:)
                  print*, 'migrate_particles_ptop: sent ipar=', &
                      ipar_mig(ileave_low(j):ileave_high(j))
                  if (present(dfp)) &
                      print*, 'migrate_particles_ptop: sent dfp=', &
                      dfp_mig(ileave_low(j):ileave_high(j),:)
                endif
              endif
            enddo
          endif
        enddo
!
!  Sum up processors that have not had place to let all migrating particles go.
!
        if (lstart.or.lmigration_redo) then   !  5-10% slowdown of code
          call mpireduce_or(lredo, lredo_all)
          call mpibcast_logical(lredo_all, 1)
        else
          lredo_all=.false.
        endif
!
!  If sum is not zero, then the while loop will be executed once more.
!
      enddo
!
    endsubroutine migrate_particles_proc_to_proc
!***********************************************************************
    subroutine migrate_particles_proc_to_block(fp,ipar,dfp)
!
!  Migrate particles from parent processors to foster parents.
!
!  28-oct-09/anders: coded
!
!  TODO: For ncpus>>1000 this subroutine possibly uses too much memory.
!
      use Diagnostics, only: max_name
!
      real, dimension (mpar_loc,mpvar) :: fp
      integer, dimension (mpar_loc) :: ipar
      real, dimension (mpar_loc,mpvar), optional :: dfp
!
      real, dimension (npar_mig,mpvar) :: fp_mig, dfp_mig
      real, save :: dx1, dy1, dz1
      integer, dimension (npar_mig) :: ipar_mig, iproc_rec_array
      integer, dimension (npar_mig) :: isort_array
      integer, dimension (0:ncpus-1) :: nmig_leave, nmig_enter
      integer, dimension (0:ncpus-1) :: ileave_low, ileave_high
      integer, dimension (0:ncpus-1) :: iproc_rec_count
      integer, dimension (0:nblockmax-1) :: ibrick_global_arr
      integer :: ix0, iy0, iz0, ipx0, ipy0, ipz0, ibx0, iby0, ibz0
      integer :: ibrick_rec, iproc_rec, nmig_enter_proc, npar_loc_start
      integer :: i, j, k, iblockl, iblocku, iblockm, ibrick_global_rec
      integer :: ibrick_global_rec_previous, nmig_leave_total, ileave_high_max
      integer :: itag_nmig=580, itag_ipar=590, itag_fp=600, itag_dfp=610
      logical :: lredo, lredo_all, lmigrate, lmigrate_previous, lreblocking
      logical, save :: lfirstcall=.true.
!
      intent (inout) :: fp, ipar, dfp
!
      if (lfirstcall) then
        dx1=1/dx; dy1=1/dy; dz1=1/dz
        lfirstcall=.false.
      endif
!
      lreblocking=lreblock_particles_run.and.it==1.and.itsub==0
!
!  Create global brick array.
!
      ibrick_global_arr(0:nblock_loc-1)= &
          iproc_parent_block(0:nblock_loc-1)*nbricks+ &
          ibrick_parent_block(0:nblock_loc-1)
      ibrick_global_rec_previous=-1
!
!  Possible to iterate until all particles have migrated.
!
      lredo=.false.; lredo_all=.true.
      npar_loc_start=npar_loc
!
      do while (lredo_all)
        lredo=.false.
!
        nmig_leave=0
        nmig_leave_total=0
        nmig_enter=0
!
        do k=npar_loc_start,1,-1
!
!  Calculate processor and brick index of particle.
!
          ix0=nghostb+1; iy0=nghostb+1; iz0=nghostb+1; ibx0=0; iby0=0; ibz0=0
          ipx0=0; ipy0=0; ipz0=0
!
          if (nxgrid/=1) then  !  Find processor and brick x-coordinate
            ix0=nint((fp(k,ixp)-xref_par)*dx1)+1
            ipx0=(ix0-1)/nx
            ix0=ix0-ipx0*nx
            ibx0=(ix0-1)/nxb
          endif
!
          if (nygrid/=1) then  !  Find processor and brick y-coordinate
            iy0=nint((fp(k,iyp)-yref_par)*dy1)+1
            ipy0=(iy0-1)/ny
            iy0=iy0-ipy0*ny
            iby0=(iy0-1)/nyb
          endif
!
          if (nzgrid/=1) then  !  Find processor and brick z-coordinate
            iz0=nint((fp(k,izp)-zref_par)*dz1)+1
            ipz0=(iz0-1)/nz
            iz0=iz0-ipz0*nz
            ibz0=(iz0-1)/nzb
          endif
!
!  Calculate processor and brick index of particle.
!
          ibrick_rec=ibx0+iby0*nbx+ibz0*nbx*nby
          iproc_rec =ipx0+ipy0*nprocx+ipz0*nprocx*nprocy
!
!  Find out whether the particle is in any block adopted by the local processor.
!
          ibrick_global_rec=iproc_rec*nbricks+ibrick_rec
          if (ibrick_global_rec==ibrick_global_rec_previous) then
            lmigrate=lmigrate_previous
          else
            lmigrate=.true.
            iblockl=0; iblocku=nblock_loc-1
            do while (abs(iblocku-iblockl)>1)
              iblockm=(iblockl+iblocku)/2
              if (ibrick_global_rec>ibrick_global_arr(iblockm)) then
                iblockl=iblockm
              else
                iblocku=iblockm
              endif
            enddo
            if (ibrick_global_rec==ibrick_global_arr(iblockl) .or. &
                ibrick_global_rec==ibrick_global_arr(iblocku)) lmigrate=.false.
          endif
          ibrick_global_rec_previous=ibrick_global_rec
!
!  Open up new block if brick where particle has moved is not adopted by
!  any processor. This may happen if the brick was previously empty.
!
          if (iproc_rec==iproc .and. iproc_foster_brick(ibrick_rec)==-1) then
            if (ip<=6) then
              print'(A,i5,A,i5)', 'migrate_particles_ptob: '// &
                  'opened brick ', ibrick_rec, ' at processor ', iproc
            endif
            iproc_foster_brick(ibrick_rec)=iproc
            nbrick_foster=nbrick_foster+1
            if (nproc_parent>=1) then
              if (.not.any(iproc==iproc_parent_list(1:nproc_parent))) then
                nproc_parent=nproc_parent+1
                iproc_parent_list(nproc_parent)=iproc
              endif
            else
              nproc_parent=nproc_parent+1
              iproc_parent_list(nproc_parent)=iproc
            endif
            if (nproc_foster>=1) then
              if (.not.any(iproc==iproc_foster_list(1:nproc_foster))) then
                nproc_foster=nproc_foster+1
                iproc_foster_list(nproc_foster)=iproc
              endif
            else
              nproc_foster=nproc_foster+1
              iproc_foster_list(nproc_foster)=iproc
            endif
            nblock_loc=nblock_loc+1
            iproc_parent_block(nblock_loc-1)=iproc
            ibrick_parent_block(nblock_loc-1)=ibrick_rec
            xb(:,nblock_loc-1)=xbrick(:,ibrick_rec)
            yb(:,nblock_loc-1)=ybrick(:,ibrick_rec)
            zb(:,nblock_loc-1)=zbrick(:,ibrick_rec)
            call sort_blocks()
            ibrick_global_arr(0:nblock_loc-1)= &
                iproc_parent_block(0:nblock_loc-1)*nbricks+ &
            ibrick_parent_block(0:nblock_loc-1)
            lmigrate=.false.
          endif
          lmigrate_previous=lmigrate
!
!  Migrate particle to foster parent, if foster parent differs from parent.
!
          if (lmigrate) then
            iproc_rec=iproc_foster_brick(ibrick_rec)
            if (ip<=7) print '(a,i8,a,i4,a,i4)', &
                'migrate_particles_proc_to_block: Particle ', ipar(k), &
                ' moves out of proc ', iproc
!
!  Copy migrating particle to the end of the fp array.
!
            nmig_leave(iproc_rec)=nmig_leave(iproc_rec)+1
            nmig_leave_total     =nmig_leave_total     +1
            if (sum(nmig_leave)>npar_mig) then
              if (.not. lstart) then
                print '(a,i3,a,i3,a)', &
                    'migrate_particles_ptob: too many particles migrating '// &
                    'from proc ', iproc
                print*, '  (npar_mig,nmig,npar_loc,k=', &
                    npar_mig, sum(nmig_leave), npar_loc, k, ')'
              endif
              if (lstart.or.lmigration_redo) then
                if (.not. lstart) then
                  print*, '  Going to do one more migration iteration!'
                  print*, '  (this may be time consuming - '// &
                      'consider setting npar_mig'
                  print*, '  higher in cparam.local)'
                endif
                nmig_leave(iproc_rec)=nmig_leave(iproc_rec)-1
                nmig_leave_total     =nmig_leave_total     -1
                lredo=.true.
                exit
              else
                call fatal_error('migrate_particles_ptob','')
              endif
            endif
            fp_mig(nmig_leave_total,:)=fp(k,:)
            if (present(dfp)) dfp_mig(nmig_leave_total,:)=dfp(k,:)
            ipar_mig(nmig_leave_total)=ipar(k)
            iproc_rec_array(nmig_leave_total)=iproc_rec
!
!  Move the particle with the highest index number to the empty spot left by
!  the migrating particle.
!
            fp(k,:)=fp(npar_loc,:)
            if (present(dfp)) dfp(k,:)=dfp(npar_loc,:)
            ipar(k)=ipar(npar_loc)
!
!  Reduce the number of particles by one.
!
            npar_loc=npar_loc-1
          endif
        enddo
        npar_loc_start=k
!
!  Print out information about number of migrating particles.
!
        if (ip<=8) print*, 'migrate_particles_ptob: iproc, nmigrate = ', &
            iproc, sum(nmig_leave)
!
!  Diagnostic about number of migrating particles.
!  WARNING: in time-steps where snapshots are written, this diagnostic
!  parameter will be zero (quite confusing)!
!
        if (ldiagnos.and.(idiag_nmigmax/=0)) &
            call max_name(sum(nmig_leave),idiag_nmigmax)
!
!  Share information about number of migrating particles. We only communicate
!  particles between processors that are either parents or foster parents of
!  each other's particles.
!
        if (nproc_foster/=0) then
          do i=1,nproc_foster
            if (iproc_foster_list(i)/=iproc) &
                call mpisend_int(nmig_leave(iproc_foster_list(i)),1, &
                iproc_foster_list(i),itag_nmig+iproc)
          enddo
        endif
        if (nproc_parent/=0) then
          do i=1,nproc_parent
            if (iproc_parent_list(i)/=iproc) &
                call mpirecv_int(nmig_enter(iproc_parent_list(i)),1, &
                iproc_parent_list(i),itag_nmig+iproc_parent_list(i))
          enddo
        endif
!
!  Check that there is room for the new particles at each processor.
!
        nmig_enter_proc=sum(nmig_enter)
        if (npar_loc+nmig_enter_proc>mpar_loc) then
          print*, 'migrate_particles_ptob: '// &
              'too many particles want to be at proc', iproc
          print*, 'migrate_particles_ptob: npar_loc, mpar_loc, nmig=', &
              npar_loc, mpar_loc, nmig_enter_proc
          call fatal_error_local('migrate_particles_ptob','')
        endif
        call fatal_error_local_collect()
!
!  Sort array of migrating particle in order of receiving processor.
!
        if (nmig_leave_total>=1) then
          ileave_high_max=0
          do i=0,ncpus-1
            if (nmig_leave(i)>=1) then
              ileave_low(i)  =ileave_high_max+1
              ileave_high(i) =ileave_low(i)+nmig_leave(i)-1
              ileave_high_max=ileave_high_max+nmig_leave(i)
            else
              ileave_low(i) =0
              ileave_high(i)=0
            endif
          enddo
          iproc_rec_count=0
          do k=1,nmig_leave_total
            isort_array(ileave_low(iproc_rec_array(k))+iproc_rec_count(iproc_rec_array(k)))=k
            iproc_rec_count(iproc_rec_array(k))= &
                iproc_rec_count(iproc_rec_array(k))+1
          enddo
          ipar_mig(1:nmig_leave_total)= &
              ipar_mig(isort_array(1:nmig_leave_total))
          fp_mig(1:nmig_leave_total,:)= &
              fp_mig(isort_array(1:nmig_leave_total),:)
          if (present(dfp)) dfp_mig(1:nmig_leave_total,:)= &
              dfp_mig(isort_array(1:nmig_leave_total),:)
        endif
!
!  Set to receive.
!
        do i=0,ncpus-1
          if (iproc/=i .and. nmig_enter(i)/=0) then
            call mpirecv_real(fp(npar_loc+1:npar_loc+nmig_enter(i),:), &
                (/nmig_enter(i),mpvar/),i,itag_fp)
            call mpirecv_int(ipar(npar_loc+1:npar_loc+nmig_enter(i)), &
                nmig_enter(i),i,itag_ipar)
            if (present(dfp)) &
                call mpirecv_real(dfp(npar_loc+1:npar_loc+nmig_enter(i),:), &
                (/nmig_enter(i),mpvar/),i,itag_dfp)
            if (ip<=6) then
              print*, 'migrate_particles_ptob: iproc, iproc_send=', iproc, i
              print*, 'migrate_particles_ptob: received fp=', &
                  fp(npar_loc+1:npar_loc+nmig_enter(i),:)
              print*, 'migrate_particles_ptob: received ipar=', &
                  ipar(npar_loc+1:npar_loc+nmig_enter(i))
              if (present(dfp)) &
                  print*, 'migrate_particles_ptob: received dfp=',&
                  dfp(npar_loc+1:npar_loc+nmig_enter(i),:)
            endif
!
            npar_loc=npar_loc+nmig_enter(i)
            if (npar_loc>mpar_loc) then
              print*, 'migrate_particles_ptob: '// &
                  'too many particles at proc', iproc
              print*, 'migrate_particles_ptob: npar_loc, mpar_loc=', &
                  npar_loc, mpar_loc
              call fatal_error('migrate_particles','')
            endif
          endif
!
!  Directed send.
!
          if (iproc==i) then
            do j=0,ncpus-1
              if (iproc/=j .and. nmig_leave(j)/=0) then
                call mpisend_real(fp_mig(ileave_low(j):ileave_high(j),:), &
                    (/nmig_leave(j),mpvar/),j,itag_fp)
                call mpisend_int(ipar_mig(ileave_low(j):ileave_high(j)), &
                    nmig_leave(j),j,itag_ipar)
                if (present(dfp)) &
                    call mpisend_real(dfp_mig(ileave_low(j):ileave_high(j),:), &
                    (/nmig_leave(j),mpvar/),j,itag_dfp)
                if (ip<=6) then
                  print*, 'migrate_particles_ptob: iproc, iproc_rec=', iproc, j
                  print*, 'migrate_particles_ptob: sent fp=', &
                      fp_mig(ileave_low(j):ileave_high(j),:)
                  print*, 'migrate_particles_ptob: sent ipar=', &
                      ipar_mig(ileave_low(j):ileave_high(j))
                  if (present(dfp)) &
                      print*, 'migrate_particles_ptob: sent dfp=', &
                      dfp_mig(ileave_low(j):ileave_high(j),:)
                endif
              endif
            enddo
          endif
        enddo
!
!  Sum up processors that have not had place to let all migrating particles go.
!
        if (lstart.or.lmigration_redo) then   !  5-10% slowdown of code
          call mpireduce_or(lredo, lredo_all)
          call mpibcast_logical(lredo_all, 1)
        else
          lredo_all=.false.
        endif
!
!  If sum is not zero, then the while loop will be executed once more.
!
      enddo
!
    endsubroutine migrate_particles_proc_to_block
!***********************************************************************
    subroutine load_balance_particles(f,fp,ipar)
!
!  This subroutine counts particles in the bricks at the local processor
!  and distributes the bricks in such a away that there is approximately
!  equal number of particles per processor.
!
!  Alternative method:
!    - Integrate np on processors (should be possible to do MPI integral)
!    - Each processor finds out if it has the boundary between two procs
!    - Use MPI_ANY_SOURCE to communicate boundary to correct processor
!  To avoid stacking light bricks at a single processor, this can be done first
!  for heavy bricks and then for light bricks.
!
!  12-oct-09/anders: coded
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (mpar_loc,mpvar) :: fp
      integer, dimension (mpar_loc) :: ipar
!
      real, dimension (mxb,0:nblockmax-1) :: xb_recv
      real, dimension (myb,0:nblockmax-1) :: yb_recv
      real, dimension (mzb,0:nblockmax-1) :: zb_recv
      integer, dimension (MPI_STATUS_SIZE) :: stat
      integer, dimension (0:nbricks-1) :: npbrick, iproc_foster_old
      integer, dimension (0:nblockmax-1) :: npblock, ibrick_give, ibrick_recv
      integer, dimension (0:nblockmax-1) :: iproc_grandparent, iproc_grandchild
      integer, dimension (0:nblockmax-1) :: iproc_parent_old, ibrick_parent_old
      integer, dimension (2*nblockmax) :: ireq_array
      integer :: npar_sum, npar_target, npar_recv, npar_requ
      integer :: npar_brick_taken, npar_want, npar_give
      integer :: ibrick, iblock, ibx, iby, ibz, di, nblock_loc_old
      integer :: iblock_old, nbrick_give, nbrick_recv, ibrick_global
      integer :: iproc_left, iproc_right, tag_id=100, ierr, ireq, nreq
      integer :: iblock1, iblock2, iproc_recv, iproc_send
      integer :: ipvar, nblock_send, npar_loc_tmp
      integer :: k1_send, k2_send
!
      if (ip<=6) then
        print*, 'load_balance_particles: iproc, npar_loc (before) =', &
            iproc, npar_loc
      endif
!
!  Count particles in bricks, based on particle mapping done in map_xxp_grid.
!
      do ibrick=0,nbricks-1
        ibx=modulo(ibrick,nbx)
        iby=modulo(ibrick/nbx,nby)
        ibz=ibrick/(nbx*nby)
        npbrick(ibrick)=sum(f(l1+ibx*nxb:l1+(ibx+1)*nxb-1, &
                              m1+iby*nyb:m1+(iby+1)*nyb-1, &
                              n1+ibz*nzb:n1+(ibz+1)*nzb-1,inp))
      enddo
!
!  For perfect load balancing we want npar/ncpus particles per processor.
!
      npar_target=npar/ncpus
!
!  Start filling up block array with own bricks, but to no more than
!  npar_target.
!
      iproc_foster_old=iproc_foster_brick
      iproc_parent_old=iproc_parent_block
      ibrick_parent_old=ibrick_parent_block
      nblock_loc_old=nblock_loc
      ibrick=0
      iblock=0
      npar_sum=0
      iproc_foster_brick=-1
      iproc_parent_block=-1
      ibrick_parent_block=-1
      do while ( (npar_sum<npar_target) .and. (ibrick<nbricks) )
        if (npbrick(ibrick)/=0) then
          iproc_parent_block(iblock)=iproc
          ibrick_parent_block(iblock)=ibrick
          iproc_foster_brick(ibrick)=iproc
          npar_sum=npar_sum+npbrick(ibrick)
          npblock(iblock)=npbrick(ibrick)
          iblock=iblock+1
        endif
        ibrick=ibrick+1
      enddo
      nblock_loc=iblock
      nbrick_foster=ibrick
      npar_brick_taken=npar_sum
!
!  Communicate with processors left and right, in increments of one.
!    - give particles to left processor
!    - receive particles from right processor
!
      do di=1,ncpus-1
!
        iproc_left =modulo(iproc-di,ncpus)
        iproc_right=modulo(iproc+di,ncpus)
!
!  Each processor calculates the number of particles required to reach the
!  targeted particle number.
!
        npar_want=0
        if (npar_sum<npar_target) npar_want=npar_target-npar_sum
!
        call MPI_SEND(npar_want, 1, MPI_INTEGER, iproc_right, &
            tag_id, MPI_COMM_WORLD, ierr)
        call MPI_RECV(npar_requ, 1, MPI_INTEGER, iproc_left, &
            tag_id, MPI_COMM_WORLD, stat, ierr)
        if (ip<=6) then
          print*, 'iproc, iproc_left, iproc_right, npar_want, npar_requ='
          print*, iproc, iproc_left, iproc_right, npar_want, npar_requ
        endif
!
!  If the left processor needs any bricks from the local processor, then find
!  out how many bricks must be given to match the wanted particle number.
!
        npar_give=0
        nbrick_give=0
        if (npar_requ>0) then
          do ibrick=nbrick_foster,nbricks-1
            if (npbrick(ibrick)/=0) then
              npar_give=npar_give+npbrick(ibrick)
              ibrick_give(nbrick_give)=ibrick
              nbrick_give=nbrick_give+1
              if (npar_give>npar_requ) exit
            endif
          enddo
          if (nbrick_give>0) then
            iproc_foster_brick(ibrick_give(0:nbrick_give-1))=iproc_left
          endif
          nbrick_foster=ibrick+1
        endif
!
!  Inform the left processor of which bricks it may adopt.
!
        npar_recv=0
        call MPI_SEND(nbrick_give, 1, MPI_INTEGER, &
            iproc_left, tag_id, MPI_COMM_WORLD, ierr)
        call MPI_RECV(nbrick_recv, 1, MPI_INTEGER, &
            iproc_right, tag_id, MPI_COMM_WORLD, stat, ierr)
        call MPI_SEND(ibrick_give(0:nbrick_give-1), nbrick_give, MPI_INTEGER, &
            iproc_left, tag_id, MPI_COMM_WORLD, ierr)
        call MPI_RECV(ibrick_recv(0:nbrick_recv-1), nbrick_recv, MPI_INTEGER, &
            iproc_right, tag_id, MPI_COMM_WORLD, stat, ierr)
        call MPI_SEND(npar_give, 1, MPI_INTEGER, &
            iproc_left, tag_id, MPI_COMM_WORLD, ierr)
        call MPI_RECV(npar_recv, 1, MPI_INTEGER, &
            iproc_right, tag_id, MPI_COMM_WORLD, stat, ierr)
!
!  Stop the code if load balancing puts too many blocks at any processor.
!
        if (nblock_loc+nbrick_recv>nblockmax) then
          print*, 'load_balance_particles: too many blocks at processor ', iproc
          print*, 'load_balance_particles: nblock_loc, nblockmax=', &
              nblock_loc+nbrick_recv, nblockmax
          call fatal_error_local('load_balance_particles','')
        endif
        call fatal_error_local_collect()
!
!  Inform the left processor of the particle contents of each adopted brick.  
!
        if (npar_give>0) call MPI_SEND(npbrick(ibrick_give(0:nbrick_give-1)), &
            nbrick_give, MPI_INTEGER, iproc_left, &
            tag_id, MPI_COMM_WORLD, ierr)
        if (npar_recv>0) call MPI_RECV(npblock(nblock_loc:nblock_loc+ &
            nbrick_recv-1), nbrick_recv, MPI_INTEGER, iproc_right, &
            tag_id, MPI_COMM_WORLD, stat, ierr)
!
        if (ip<=6) then
          print*, 'iproc, iproc_left, iproc_right, npar_give, npar_recv', &
              iproc, iproc_left, iproc_right, npar_give, npar_recv
        endif
!
!  Register the bricks received from the right processor.
!
        if (npar_recv>0) then
          do iblock=0,nbrick_recv-1
            iproc_parent_block(nblock_loc+iblock)=iproc_right
            ibrick_parent_block(nblock_loc+iblock)=ibrick_recv(iblock)
          enddo
          nblock_loc=nblock_loc+nbrick_recv
          npar_sum=npar_sum+npar_recv
        endif
!
        if (npar_give>0) npar_brick_taken=npar_brick_taken+npar_give
!
      enddo
!
!  Now each processor has a list of particle blocks that would lead to
!  good load balancing.
!
      if (ip<=6) then
        print*, 'load_balance_particles: iproc, nblock_loc, npar_sum=', &
            iproc, nblock_loc, npar_sum
        print*, 'load_balance_particles: iproc, iproc_parent_block=', &
            iproc, iproc_parent_block(0:nblock_loc-1)
        print*, 'load_balance_particles: iproc, iproc_foster_brick=', &
            iproc, iproc_foster_brick(0:nbricks-1)
        print*, 'load_balance_particles: iproc, ibrick_parent_block=', &
            iproc, ibrick_parent_block(0:nblock_loc-1)
      endif
!
!  Next we need to communicate the redistributed particles.
!  First make a 'grand parent' list. This tells a processor where to look
!  for particles for its blocks. This is generally not with the parent, but
!  with the processor that adopted the block earlier - which we call the grand
!  parent.
!
      iproc_grandparent=iproc_parent_block
      nreq=0
      ibrick=0
      do while (ibrick<nbricks)
        if (iproc_foster_brick(ibrick)/=-1) then
          call MPI_ISEND(iproc_foster_old(ibrick), 1, MPI_INTEGER, &
              iproc_foster_brick(ibrick), tag_id+ibrick, MPI_COMM_WORLD, &
              ireq, ierr)
          nreq=nreq+1
          ireq_array(nreq)=ireq
        endif 
        ibrick=ibrick+1
      enddo
!
      iblock=0
      do while (iblock<nblock_loc)
        call MPI_IRECV(iproc_grandparent(iblock), 1, MPI_INTEGER, &
            iproc_parent_block(iblock), tag_id+ibrick_parent_block(iblock), &
            MPI_COMM_WORLD, ireq, ierr)
        nreq=nreq+1
        ireq_array(nreq)=ireq
        iblock=iblock+1
      enddo
!
      do ireq=1,nreq
        call MPI_WAIT(ireq_array(ireq),stat,ierr)
      enddo
!
!  Each grand parent processor must know where to send the previously
!  adopted bricks next. We make sure here to send also information about empty
!  blocks, since such a block could have been non-empty when the grand parent
!  got it.
!
      nreq=0
      ibrick=0
      do while (ibrick<nbricks)
        if (iproc_foster_old(ibrick)/=-1) then
          call MPI_ISEND(iproc_foster_brick(ibrick), 1, MPI_INTEGER, &
              iproc_foster_old(ibrick), tag_id+ibrick, MPI_COMM_WORLD, &
              ireq, ierr)
          nreq=nreq+1
          ireq_array(nreq)=ireq
        endif
        ibrick=ibrick+1
      enddo
!
      iproc_grandchild=iproc_parent_block
      iblock=0
      do while (iblock<nblock_loc_old)
        call MPI_IRECV(iproc_grandchild(iblock), 1, MPI_INTEGER, &
            iproc_parent_old(iblock), tag_id+ibrick_parent_old(iblock), &
            MPI_COMM_WORLD, ireq, ierr)
        nreq=nreq+1
        ireq_array(nreq)=ireq
        iblock=iblock+1
      enddo
!
      do ireq=1,nreq
        call MPI_WAIT(ireq_array(ireq),stat,ierr)
      enddo
!
      if (ip<=6) then
        print*, 'load_balance_particles: iproc, iproc_grandparent', &
            iproc, iproc_grandparent(0:nblock_loc-1)
        print*, 'load_balance_particles: iproc, iproc_grandchild', &
            iproc, iproc_grandchild(0:nblock_loc_old-1)
      endif
!
!  The particles are sent to the foster processor by non-blocking MPI
!  communication. We use here non-blocking in order to be able to issue
!  first all the receive commands and then all the send commands.
!
!  Non-blocking MPI only works on contiguous arrays. Thus we communicate
!  one particle variable at a time.
!
      do ipvar=1,mpvar
        npar_loc_tmp=npar_loc  ! we do not want to add to npar_loc mpvar times
        nreq=0
        iblock=0
        do while (iblock<nblock_loc)
          iproc_recv=iproc_grandparent(iblock)
          npar_recv=npblock(iblock)
          if (iproc/=iproc_recv) then
            if (npar_loc_tmp+npar_recv>mpar_loc) then
              print*, 'load_balance_particles: '// &
                  'Too many particles want to be at proc', iproc
              print*, 'load_balance_particles: npar_loc, mpar_loc, npar_recv=',&
                  npar_loc, mpar_loc, npar_recv
              call fatal_error_local('load_balance_particles','')
            endif
            ibrick_global= &
                iproc_parent_block(iblock)*nbricks+ibrick_parent_block(iblock)
            call MPI_IRECV(fp(npar_loc_tmp+1:npar_loc_tmp+npar_recv,ipvar), &
                npar_recv, MPI_DOUBLE_PRECISION, iproc_recv, &
                tag_id+ibrick_global, MPI_COMM_WORLD, ireq, ierr)
            nreq=nreq+1
            ireq_array(nreq)=ireq
            npar_loc_tmp=npar_loc_tmp+npar_recv
          endif
          iblock=iblock+1
        enddo
!
!  Initiate non-blocking send of particles.
!
        iblock=0
        do while (iblock<nblock_loc_old)
          iproc_send=iproc_grandchild(iblock)
          k1_send=k1_iblock(iblock)
          k2_send=k2_iblock(iblock)
          if (iproc_send/=iproc .and. iproc_send/=-1) then
            ibrick_global= &
                iproc_parent_old(iblock)*nbricks+ibrick_parent_old(iblock)
            call MPI_ISEND(fp(k1_send:k2_send,ipvar),(k2_send-k1_send+1), &
                MPI_DOUBLE_PRECISION, iproc_send, tag_id+ibrick_global, &
                MPI_COMM_WORLD, ireq, ierr)
            nreq=nreq+1
            ireq_array(nreq)=ireq
          endif
          iblock=iblock+1
        enddo
!
!  Make sure that non-blocking communication of particles has finished before
!  continuing.
!
        do ireq=1,nreq
          call MPI_WAIT(ireq_array(ireq),stat,ierr)
        enddo
!
      enddo
!
!  We continue to send the index number of the particles.
!
      npar_loc_tmp=npar_loc
      nreq=0
      iblock=0
      do while (iblock<nblock_loc)
        iproc_recv=iproc_grandparent(iblock)
        npar_recv=npblock(iblock)
        if (iproc/=iproc_recv) then
          ibrick_global= &
              iproc_parent_block(iblock)*nbricks+ibrick_parent_block(iblock)
          call MPI_IRECV(ipar(npar_loc_tmp+1:npar_loc_tmp+npar_recv), &
              npar_recv, MPI_INTEGER, iproc_recv, &
              tag_id+ibrick_global, MPI_COMM_WORLD, ireq, ierr)
          nreq=nreq+1
          ireq_array(nreq)=ireq
          npar_loc_tmp=npar_loc_tmp+npar_recv
        endif
        iblock=iblock+1
      enddo
!
      iblock=0
      do while (iblock<nblock_loc_old)
        iproc_send=iproc_grandchild(iblock)
        k1_send=k1_iblock(iblock)
        k2_send=k2_iblock(iblock)
        if (iproc_send/=iproc .and. iproc_send/=-1) then
          ibrick_global= &
              iproc_parent_old(iblock)*nbricks+ibrick_parent_old(iblock)
          call MPI_ISEND(ipar(k1_send:k2_send),(k2_send-k1_send+1), &
              MPI_INTEGER, iproc_send, tag_id+ibrick_global, &
              MPI_COMM_WORLD, ireq, ierr)
          nreq=nreq+1
          ireq_array(nreq)=ireq
        endif
        iblock=iblock+1
      enddo
!
      do ireq=1,nreq
        call MPI_WAIT(ireq_array(ireq),stat,ierr)
      enddo
!
!  Increase particle number according to received blocks.
!
      npar_loc=npar_loc_tmp
!
!  Communicate xb, yb, zb arrays. We allow self-communication here, although
!  transfer within a processor could be done by some intelligent copying.
!
      nreq=0
      iblock=0
      do while (iblock<nblock_loc)
        iproc_recv=iproc_grandparent(iblock)
        ibrick_global= &
            iproc_parent_block(iblock)*nbricks+ibrick_parent_block(iblock)
        call MPI_IRECV(xb_recv(:,iblock:iblock), mxb, &
            MPI_DOUBLE_PRECISION, iproc_recv, &
            tag_id+ibrick_global, MPI_COMM_WORLD, ireq, ierr)
        nreq=nreq+1
        ireq_array(nreq)=ireq
        iblock=iblock+1
      enddo
!
      iblock=0
      do while (iblock<nblock_loc_old)
        iproc_send=iproc_grandchild(iblock)
        if (iproc_send/=-1) then
          ibrick_global= &
              iproc_parent_old(iblock)*nbricks+ibrick_parent_old(iblock)
          call MPI_ISEND(xb(:,iblock:iblock), mxb, &
              MPI_DOUBLE_PRECISION, iproc_send, &
              tag_id+ibrick_global, MPI_COMM_WORLD, ireq, ierr)
          nreq=nreq+1
          ireq_array(nreq)=ireq
        endif
        iblock=iblock+1
      enddo
!
      do ireq=1,nreq
        call MPI_WAIT(ireq_array(ireq),stat,ierr)
      enddo
!
      xb(:,0:nblock_loc-1)=xb_recv(:,0:nblock_loc-1)
!
!  Communicate yb array.
!
      nreq=0
      iblock=0
      do while (iblock<nblock_loc)
        iproc_recv=iproc_grandparent(iblock)
        ibrick_global= &
            iproc_parent_block(iblock)*nbricks+ibrick_parent_block(iblock)
        call MPI_IRECV(yb_recv(:,iblock:iblock), &
            myb, MPI_DOUBLE_PRECISION, iproc_recv, &
            tag_id+ibrick_global, MPI_COMM_WORLD, ireq, ierr)
        nreq=nreq+1
        ireq_array(nreq)=ireq
        iblock=iblock+1
      enddo
!
      iblock=0
      do while (iblock<nblock_loc_old)
        iproc_send=iproc_grandchild(iblock)
        if (iproc_send/=-1) then
          ibrick_global= &
              iproc_parent_old(iblock)*nbricks+ibrick_parent_old(iblock)
          call MPI_ISEND(yb(:,iblock:iblock), myb, &
              MPI_DOUBLE_PRECISION, iproc_send, &
              tag_id+ibrick_global, MPI_COMM_WORLD, ireq, ierr)
          nreq=nreq+1
          ireq_array(nreq)=ireq
        endif
        iblock=iblock+1
      enddo
!
      do ireq=1,nreq
        call MPI_WAIT(ireq_array(ireq),stat,ierr)
      enddo
!
      yb(:,0:nblock_loc-1)=yb_recv(:,0:nblock_loc-1)
!
!  Communicate zb array.
!
      nreq=0
      iblock=0
      do while (iblock<nblock_loc)
        iproc_recv=iproc_grandparent(iblock)
        ibrick_global= &
            iproc_parent_block(iblock)*nbricks+ibrick_parent_block(iblock)
        call MPI_IRECV(zb_recv(:,iblock:iblock), mzb, &
            MPI_DOUBLE_PRECISION, iproc_recv, &
            tag_id+ibrick_global, MPI_COMM_WORLD, ireq, ierr)
        nreq=nreq+1
        ireq_array(nreq)=ireq
        iblock=iblock+1
      enddo
!
      iblock=0
      do while (iblock<nblock_loc_old)
        iproc_send=iproc_grandchild(iblock)
        if (iproc_send/=-1) then
          ibrick_global= &
              iproc_parent_old(iblock)*nbricks+ibrick_parent_old(iblock)
          call MPI_ISEND(zb(:,iblock:iblock), mzb, &
              MPI_DOUBLE_PRECISION, iproc_send, &
              tag_id+ibrick_global, MPI_COMM_WORLD, ireq, ierr)
          nreq=nreq+1
          ireq_array(nreq)=ireq
        endif
         iblock=iblock+1
      enddo
!
      do ireq=1,nreq
        call MPI_WAIT(ireq_array(ireq),stat,ierr)
      enddo
!
      zb(:,0:nblock_loc-1)=zb_recv(:,0:nblock_loc-1)
!
!  Remove the particles that are no longer at the present processor.
!
      iblock=0
      do while (iblock<nblock_loc_old)
        iproc_send=iproc_grandchild(iblock)
        k1_send=k1_iblock(iblock)
        k2_send=k2_iblock(iblock)
        if (iproc_send/=iproc .and. iproc_send/=-1) then
          nblock_send=k2_send-k1_send+1
          fp(k1_send:npar_loc-nblock_send,:)=fp(k2_send+1:npar_loc,:)
          ipar(k1_send:npar_loc-nblock_send)=ipar(k2_send+1:npar_loc)
          npar_loc=npar_loc-nblock_send
          k1_iblock(iblock)=0
          k2_iblock(iblock)=0
          k1_iblock(iblock+1:nblock_loc_old-1)= &
              k1_iblock(iblock+1:nblock_loc_old-1)-nblock_send
          k2_iblock(iblock+1:nblock_loc_old-1)= &
              k2_iblock(iblock+1:nblock_loc_old-1)-nblock_send
        endif
        iblock=iblock+1
      enddo
!
!  Make a list of foster parents, for communicating migrating particles later.
!
      nproc_foster=0
      ibrick=0
      do while (ibrick<nbricks)
        if (iproc_foster_brick(ibrick)/=-1) then
          if (nproc_foster==0) then
            nproc_foster=nproc_foster+1
            iproc_foster_list(nproc_foster)=iproc_foster_brick(ibrick)
          else
            if (.not.any(iproc_foster_brick(ibrick)== &
                         iproc_foster_list(1:nproc_foster))) then
              nproc_foster=nproc_foster+1
              iproc_foster_list(nproc_foster)=iproc_foster_brick(ibrick)
            endif
          endif
        endif
        ibrick=ibrick+1
      enddo
!
!  Sort the blocks by parent processors and by parent brick index.
!
      call sort_blocks()
!
!  Make a list of parents, for communicating migrating particles later.
!
      nproc_parent=0
      iblock=0
      do while (iblock<nblock_loc)
        if (iproc_parent_block(iblock)/=-1) then
          if (nproc_parent==0) then
            nproc_parent=nproc_parent+1
            iproc_parent_list(nproc_parent)=iproc_parent_block(iblock)
          else
            if (.not.any(iproc_parent_block(iblock)== &
                         iproc_parent_list(1:nproc_parent))) then
              nproc_parent=nproc_parent+1
              iproc_parent_list(nproc_parent)=iproc_parent_block(iblock)
            endif
          endif
        endif
        iblock=iblock+1
      enddo
!
      if (ip<=6) then
        print*, 'load_balance_particles: iproc, npar_loc (after ) =', &
            iproc, npar_loc
      endif
!
    endsubroutine load_balance_particles
!***********************************************************************
    subroutine output_blocks(filename)
!
!  Write block domain decomposition to file.
!
!  04-nov-09/anders: coded
!
      use Io, only: lun_output
!
      character(len=*) :: filename
!
      intent (in) :: filename
!
      open(lun_output,file=filename,form='unformatted')
!
        write(lun_output) t
        write(lun_output) nblock_loc, nproc_parent, nproc_foster
        write(lun_output) iproc_foster_brick
        if (nblock_loc>0) then
          write(lun_output) iproc_parent_block(0:nblock_loc-1)
          write(lun_output) ibrick_parent_block(0:nblock_loc-1)
          write(lun_output) xb(:,0:nblock_loc-1)
          write(lun_output) yb(:,0:nblock_loc-1)
          write(lun_output) zb(:,0:nblock_loc-1)
        else
          write(lun_output) -1
          write(lun_output) -1
          write(lun_output) -1
          write(lun_output) -1
          write(lun_output) -1
        endif
        if (nproc_parent>0) then
          write(lun_output) iproc_parent_list(1:nproc_parent)
        else
          write(lun_output) -1
        endif
        if (nproc_foster>0) then
          write(lun_output) iproc_foster_list(1:nproc_foster)
        else
          write(lun_output) -1
        endif
!
      close(lun_output)
!
    endsubroutine output_blocks
!***********************************************************************
    subroutine input_blocks(filename)
!
!  Read block domain decomposition from file.
!
!  04-nov-09/anders: coded
!
      use Io, only: lun_output
!
      character(len=*) :: filename
!
      real :: t_block
      integer :: dummy
!
      intent (in) :: filename
!
      iproc_parent_block=-1
      ibrick_parent_block=-1
      iproc_foster_brick=-1
!
      open(lun_output,file=filename,form='unformatted')
!
        read(lun_output) t_block
        read(lun_output) nblock_loc, nproc_parent, nproc_foster
        read(lun_output) iproc_foster_brick
        if (nblock_loc>0) then
          read(lun_output) iproc_parent_block(0:nblock_loc-1)
          read(lun_output) ibrick_parent_block(0:nblock_loc-1)
          read(lun_output) xb(:,0:nblock_loc-1)
          read(lun_output) yb(:,0:nblock_loc-1)
          read(lun_output) zb(:,0:nblock_loc-1)
        else
          read(lun_output) dummy
          read(lun_output) dummy
          read(lun_output) dummy
          read(lun_output) dummy
          read(lun_output) dummy
        endif
        if (nproc_parent>0) then
          read(lun_output) iproc_parent_list(1:nproc_parent)
        else
          read(lun_output) iproc_parent_list(1)
        endif
        if (nproc_foster>0) then
          read(lun_output) iproc_foster_list(1:nproc_foster)
        else
          read(lun_output) iproc_foster_list(1)
        endif
!
      close(lun_output)
!
    endsubroutine input_blocks
!***********************************************************************
    subroutine sort_blocks()
!
!  Sort the blocks by parent processor and by parent brick index.
!
!  04-nov-09/anders: coded
!
      integer, dimension (0:ncpus-1) :: nblock_iproc, iiproc, i1_iproc, i2_iproc
      integer, dimension (0:nbricks-1) :: nblock_ibrick, iibrick
      integer, dimension (0:nbricks-1) :: i1_ibrick, i2_ibrick
      integer, dimension (0:nblockmax-1) :: i_sorted_proc, i_sorted_brick
      integer :: i, iproc2, ib
!
      nblock_iproc=0
!
!  Calculate the number of blocks from each processor.
!
      do i=0,nblock_loc-1
        nblock_iproc(iproc_parent_block(i))= &
            nblock_iproc(iproc_parent_block(i))+1
      enddo
!
!  Calculate beginning and ending block index for each processor.
!
      i=0
      do iproc2=0,ncpus-1
        if (nblock_iproc(iproc2)/=0) then
          i1_iproc(iproc2)=i
          i2_iproc(iproc2)=i1_iproc(iproc2)+nblock_iproc(iproc2)-1
          i=i+nblock_iproc(iproc2)
        else
          i1_iproc(iproc2)=0
          i2_iproc(iproc2)=0
        endif
      enddo
!
!  Sort blocks according to parent processor.
!
      iiproc=i1_iproc
      do i=0,nblock_loc-1
        i_sorted_proc(iiproc(iproc_parent_block(i)))=i
        iiproc(iproc_parent_block(i))=iiproc(iproc_parent_block(i))+1
      enddo
      iproc_parent_block(0:nblock_loc-1)= &
          iproc_parent_block(i_sorted_proc(0:nblock_loc-1))
      ibrick_parent_block(0:nblock_loc-1)= &
          ibrick_parent_block(i_sorted_proc(0:nblock_loc-1))
      xb(:,0:nblock_loc-1)=xb(:,i_sorted_proc(0:nblock_loc-1))
      yb(:,0:nblock_loc-1)=yb(:,i_sorted_proc(0:nblock_loc-1))
      zb(:,0:nblock_loc-1)=zb(:,i_sorted_proc(0:nblock_loc-1))
!
!  Calculate the number of particles in each brick.
!
      do iproc2=0,ncpus-1
        nblock_ibrick=0
        if (nblock_iproc(iproc2)/=0) then
          do i=i1_iproc(iproc2),i2_iproc(iproc2)
            nblock_ibrick(ibrick_parent_block(i))= &
                nblock_ibrick(ibrick_parent_block(i))+1
          enddo
!
!  Calculate beginning and ending particle index for each brick.
!
          i=i1_iproc(iproc2)
          do ib=0,nbricks-1
            if (nblock_ibrick(ib)/=0) then
              i1_ibrick(ib)=i
              i2_ibrick(ib)=i1_ibrick(ib)+nblock_ibrick(ib)-1
              i=i+nblock_ibrick(ib)
            else
              i1_ibrick(ib)=0
              i2_ibrick(ib)=0
            endif
          enddo
          iibrick=i1_ibrick
          do i=i1_iproc(iproc2),i2_iproc(iproc2)
            i_sorted_brick(iibrick(ibrick_parent_block(i)))=i
            iibrick(ibrick_parent_block(i))=iibrick(ibrick_parent_block(i))+1
          enddo
        endif
      enddo
!
!  Sort blocks according to parent brick.
!
      iproc_parent_block(0:nblock_loc-1)= &
          iproc_parent_block(i_sorted_brick(0:nblock_loc-1))
      ibrick_parent_block(0:nblock_loc-1)= &
          ibrick_parent_block(i_sorted_brick(0:nblock_loc-1))
      xb(:,0:nblock_loc-1)=xb(:,i_sorted_brick(0:nblock_loc-1))
      yb(:,0:nblock_loc-1)=yb(:,i_sorted_brick(0:nblock_loc-1))
      zb(:,0:nblock_loc-1)=zb(:,i_sorted_brick(0:nblock_loc-1))
!
    endsubroutine sort_blocks
!***********************************************************************
    subroutine report_missing_particles(message)
!
      use Mpicomm, only: mpireduce_sum_int
!
      character (len=*) :: message
!
      integer :: npar_found
!
      npar_found=0
!
      call mpireduce_sum_int(npar_loc,npar_found)
      call mpibcast_int(npar_found,1)
!
      if (npar_found/=npar) then
        if (lroot) then
          print*, 'report_missing_particles: there are particles missing'
          print*, 'report_missing_particles: npar, npar_found=', &
              npar, npar_found
          print*, 'report_missing_particles: it, itsub, t=', &
              it, itsub, t
          print*, 'report_missing_particles: message=', message
        endif
        call fatal_error('report_missing_particles','')
      endif
!
    endsubroutine report_missing_particles
!***********************************************************************
endmodule Particles_mpicomm
