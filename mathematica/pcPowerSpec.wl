(* ::Package:: *)

(* :Name: pcPowerSpec` *)
(* :Author: Hongzhe Zhou, Stockholm, 2022*)
(* :Version: 0.1 *)
(* :Summary:
    Some functions to compute power spectra.
*)


BeginPackage["pcPowerSpec`"]


(* ::Chapter:: *)
(*Usage messages*)


powerTS::usage="powerTS[ts] computes PSD of light curves. The normalization is
Total[psd] = mean of flux^2.
Input:
  ts: 1D List of time series, { {t1,f1},{t2,f2},... }. If t_i are equally distributed,
      the built-in Fourier function shall be used which is the default. Otherwise, use
      \"lFTbyHand\"->True to do the Fourier transform by hand.
Options:
  \"lFTbyHand\": if -> True, then force to do Fourier transform by hand.
Output:
  PSD { {k1,p1},{k2,p2},... } where k1=0 is the zero mode."

power1D::usage="power1D[data,{nx,ny,nz}] computes the 1D power spectrum of data. The normalization is
Total[powerSpectrum]=Mean[data^2].
Input:
  data: 1D List of dimension {nx,ny,nz}: { f111, f112, f113, ..., f121, f122, ... }.
Output:
  The power spectrum as a List of length Max[nx,ny,nz]/2, corresponding to wavenumbers 0,1,2,..."

power1DintZ::usage="power1DintZ[data,nx,Options] first does an integration over z, then
computes the 1D power spectrum in the xy plane. The normalization is Total[powerSpectrum]=Total[data^2].
Input:
  data: 1D List of length nx^3. By default it assumes the data corresponds to the coordinates
        {{x1,y1,z1},{x2,y1,z1},...}, but this can be changed by the option \"lxyz\".
Output:
  The power spectrum as a List of length nx/2, corresponding to wavenumbers 0,1,2,...,nx/2-1.
Options:
  \"lxyz\": By default \"xyz\". This can be changed to be \"zyx\" to instruct that the data
            is in the order {{x1,y1,z1},{x1,y1,z2},...}."


Begin["`Private`"]


(* ::Chapter:: *)
(*Functions*)


(* ::Section:: *)
(*1D power spectrum*)


Options[powerTS]={"lFTbyHand"->False}
powerTS[ts_List,OptionsPattern[]]:=Module[{t,f,n,n2,T,dt,k,fft,psd},
  {t,f}=Transpose[ts];
  dt=t//Differences//Mean;
  n=Length[t];

  If[OptionValue["lFTbyHand"],
    (* do integration by hand *)
    If[EvenQ[n],{t,f}=Rest/@{t,f}];
    {t,f}=Rest/@{t,f};
    T=t[[-1]]-t[[1]];
    n=n-1;
    
    k=2\[Pi]/T*Range[0,n/2];
    fft=Total[f*Exp[-I*#*t]*dt]&/@k;
    psd=Abs[fft]^2;
    psd[[2;;]]=2*psd[[2;;]],
    
    (* use built-in Fourier *)
    T=t[[-1]]-t[[1]];
    t=Flatten@{0,t};
    f=Flatten@{0,f};
    n=n+1;
    n2=Floor[n/2];
    k=2\[Pi]/T*Range[0,n2];
    fft=Fourier[f,FourierParameters->{-1,-1}];
    psd=Abs[fft[[2;;n2+1]]]^2+Abs[fft[[-1;;-n2;;-1]]]^2;
    psd=Flatten@{Abs[fft[[1]]]^2,psd};
  ];
  psd=psd/Total[psd*2\[Pi]/T]*Total[f^2*dt];
  Transpose[{k,psd}]
]

(* shell-integrated power spectrum *)
Options[power1D]={"Method"->"kxyz1"}
power1D[data_,{nx_,ny_,nz_},Lxyz_List:{2\[Pi],2\[Pi],2\[Pi]},OptionsPattern[]]:=
  Module[{nk,kxyz,fnorm,kshell,power,pos},
  
  (* kx, ky, and kz coordinates *)
  (* assume Lxyz=2\[Pi] for now *)
  nk={nx,ny,nz};
  kxyz=N@Outer[List,Sequence@@Map[Join[Range[0,#1/2-1],Range[-#1/2,-1]]&,nk]]//Flatten[#,2]&;
  
  Switch[OptionValue["Method"],
    (* shell integration; use coarse grid *)
    "kxyz1",
      fnorm=Identity; kshell=Range[0,Min[nk]/2-1],
    (* shell integration; use fine grid *)
    "kxyz2",
      fnorm=Identity; kshell=Range[0,Max[nk]/2-1],
    (* Norm[{kx,ky}] shells *)
    "kxy",
      fnorm=Most; kshell=Range[0,Max[nk[[1;;2]]]/2-1],
    (* kz shells *)
    "kz",
      fnorm=Last; kshell=Range[0,nk[[-1]]/2-1]
  ];
  
  (* Fourier power *)
  power=ArrayReshape[data,{nx,ny,nz}]//Fourier//Flatten;
  power=power*Conjugate[power];
  
  (* do integration *)
  pos=Position[Round@*Norm@*fnorm/@kxyz,#]&/@kshell;
  power=Re@Total[Extract[power,#]]&/@pos;
  
  Return@Transpose[{kshell,power/Total[power]*Mean[data^2]}]
]


(* first integrate over z, then compute 1d power spectrum in the xy plane *)
Options[power1DintZ]={"lxyz"->"xyz"};
power1DintZ[data_,nx_,OptionsPattern[]]:=Module[{xy,data1,fft,kx,kxy,knorm,kshell,pos,power},
  xy=Switch[OptionValue["lxyz"],
    (* {{x1,y1},{x2,y1},...} *)
    "xyz",Table[{i,j},{k,nx},{j,nx},{i,nx}]//Flatten[#,2]&,
    (* {{x1,y1},{x1,y2},...} *)
    "zyx",Table[{i,j},{i,nx},{j,nx},{k,nx}]//Flatten[#,2]&
  ];
  (* Gather data by their xy coordinates *)
  data1={xy,data}//Transpose//GatherBy[#,First]&;
  (* Integration over z; now the data is alwyas in the {{x1,y1},{x1,y2},...} order *)
  data1=Last/@Sort[Total/@data1];
  (* Put data back into a squre, do fft, and back to a 1D List again *)
  data1=Partition[data1,nx];
  fft=Flatten@Fourier[data1];
  
  (* kx and ky coordiantes *)
  kx=N@Range[0,nx-1]/.x_/;x>(nx/2-1):>x-nx;
  kxy=Outer[List,kx,kx]//Flatten[#,1]&;
  knorm=Norm/@kxy;
  (* kr, and determine which positions belongs to each kr *)
  kshell=Range[0,nx/2-1];
  pos=Position[knorm,x_/;Round[x]==#]&/@kshell;

  (* shell integration and normalization*)
  power=Re[Total[Extract[fft*Conjugate[fft],#]]&/@pos];
  Return[power/Total[power]*Total[data^2]]
]


(* ::Chapter:: *)
(*End*)


End[]


Protect[
  powerTS,power1D,power1DintZ
]


EndPackage[]
