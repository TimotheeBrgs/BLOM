! Copyright (C) 2022  j. maerz
!
! This file is part of BLOM/iHAMOCC.
!
! BLOM is free software: you can redistribute it and/or modify it under the
! terms of the GNU Lesser General Public License as published by the Free
! Software Foundation, either version 3 of the License, or (at your option)
! any later version.
!
! BLOM is distributed in the hope that it will be useful, but WITHOUT ANY
! WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
! FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for
! more details.
!
! You should have received a copy of the GNU Lesser General Public License
! along with BLOM. If not, see https://www.gnu.org/licenses/.

module mo_extNwatercol
  !****************************************************************
  !
  ! MODULE mo_extNwatercol - (microbial) biological processes of the
  !                          extended nitrogen cycle
  !
  ! j.maerz 25.04.2022
  !
  ! Purpose:
  ! --------
  ! - representing major biological parts of the extended nitrogen cycle
  !
  ! Description:
  ! ------------
  ! The module holds the sequentially operated processes of
  ! - nitrification
  ! - denitrification/dissimilatory nitrate reduction from NO3 to NO2
  ! - anammox
  ! - denitrification processes from NO2 -> N2O -> N2 and DNRA
  !   (dissimilatory nitrite reduction to ammonium)
  !
  ! The process of ammonium and nitrate uptake by phytoplankton
  ! is handled in ocprod.
  !
  ! Ammonification (PON -> NH4) is also handled in ocprod.
  !
  ! The respective sediment processes are handled in:
  !     - powach.F90 and
  !     - mo_extNsediment.F90
  !
  !****************************************************************
  use mo_vgrid,       only: dp_min
  use mod_xc,         only: mnproc
  use mo_kind,        only: rp
  use mo_param1_bgc,  only: ialkali,ianh4,iano2,ian2o,iano3,idet,igasnit,iiron,ioxygen,iphosph,    &
                          & isco212
  use mo_carbch,      only: ocetra
  use mo_param_bgc,   only: riron,rnit,rcar,rnoi,                                                  &
                          & q10ano3denit,sc_ano3denit,Trefano3denit,rano3denit,bkano3denit,        &
                          & rano2anmx,q10anmx,Trefanmx,alphaanmx,bkoxanmx,bkano2anmx,bkanh4anmx,   &
                          & rano2denit,q10ano2denit,Trefano2denit,bkoxano2denit,bkano2denit,       &
                          & ran2odenit,q10an2odenit,Trefan2odenit,bkoxan2odenit,bkan2odenit,       &
                          & rdnra,q10dnra,Trefdnra,bkoxdnra,bkdnra,ranh4nitr,q10anh4nitr,          &
                          & Trefanh4nitr,bkoxamox,bkanh4nitr,bkamoxn2o,bkyamox,                    &
                          & rano2nitr,q10ano2nitr,Trefano2nitr,bkoxnitr,bkano2nitr,n2omaxy,        &
                          & n2oybeta,NOB2AOAy,bn2o,mufn2o,                                         &
                          & rc2n,ro2nnit,rnoxp,rnoxpi,rno2anmx,rno2anmxi,rnh4anmx,                 &
                          & rnh4anmxi,rno2dnra,rno2dnrai,rnh4dnra,rnh4dnrai,rnm1,                  &
                          & bkphyanh4,bkphyano3,bkphosph,bkiron,ro2utammo,max_limiter
  use mo_biomod,      only: nitr_NH4,nitr_NO2,nitr_N2O_prod,nitr_NH4_OM,nitr_NO2_OM,denit_NO3,     &
                          & denit_NO2,denit_N2O,DNRA_NO2,anmx_N2_prod,anmx_OM_prod
  implicit none

  private

  ! public functions
  public :: nitrification,denit_NO3_to_NO2,anammox,denit_dnra,extN_inv_check

  real(rp) :: eps    = epsilon(1._rp)

contains

  subroutine nitrification(kpie,kpje,kpke,kbnd,pddpo,omask,ptho)
    ! Nitrification processes (NH4 -> NO2, NO2 -> NO3) accompanied
    ! by dark carbon fixation and O2-dependent N2O production

    integer, intent(in) :: kpie,kpje,kpke,kbnd
    real(rp),intent(in) :: omask(kpie,kpje)
    real(rp),intent(in) :: pddpo(kpie,kpje,kpke)
    real(rp),intent(in) :: ptho(1-kbnd:kpie+kbnd,1-kbnd:kpje+kbnd,kpke)

    !local variables
    integer :: i,j,k
    real(rp):: Tdepanh4,O2limanh4,nut1lim,anh4new,potdnh4amox,fdetamox,fno2,fn2o,ftotnh4
    real(rp):: Tdepano2,O2limano2,nut2lim,ano2new,potdno2nitr,fdetnitr,ftotno2,no2fn2o,no2fno2,    &
               no2fdetamox
    real(rp):: amoxfrac,nitrfrac,totd,amox,nitr,temp

    ! Set output-related fields to zero
    nitr_NH4      = 0._rp
    nitr_NO2      = 0._rp
    nitr_N2O_prod = 0._rp
    nitr_NH4_OM   = 0._rp
    nitr_NO2_OM   = 0._rp

    !$OMP PARALLEL DO PRIVATE(i,k,Tdepanh4,O2limanh4,nut1lim,anh4new,potdnh4amox,fdetamox,fno2,    &
    !$OMP                     fn2o,ftotnh4,Tdepano2,O2limano2,nut2lim,ano2new,potdno2nitr,fdetnitr,&
    !$OMP                     ftotno2,amoxfrac,nitrfrac,totd,amox,nitr,temp,no2fn2o,no2fno2,       &
    !$OMP                     no2fdetamox)
    do j = 1,kpje
      do i = 1,kpie
        do k = 1,kpke
          if(pddpo(i,j,k) > dp_min .and. omask(i,j) > 0.5_rp) then
            potdnh4amox = 0._rp
            fn2o        = 0._rp
            fno2        = 0._rp
            fdetamox    = 0._rp
            potdno2nitr = 0._rp
            fdetnitr    = 0._rp

            temp = merge(ptho(i,j,k),10._rp,ptho(i,j,k) < 40._rp)
            ! Ammonium oxidation step of nitrification
            Tdepanh4    = q10anh4nitr**((temp-Trefanh4nitr)/10._rp)
            O2limanh4   = ocetra(i,j,k,ioxygen)/(ocetra(i,j,k,ioxygen) + bkoxamox)
            nut1lim     = ocetra(i,j,k,ianh4)/(ocetra(i,j,k,ianh4) + bkanh4nitr)
            anh4new     = ocetra(i,j,k,ianh4)/(1._rp + ranh4nitr*Tdepanh4*O2limanh4*nut1lim)
            potdnh4amox = max(0._rp,ocetra(i,j,k,ianh4) - anh4new)

            ! pathway splitting function  similar to Santoros et al. 2021, Ji et al. 2018
            fn2o     = mufn2o * (bn2o + (1._rp-bn2o)*bkoxamox/(ocetra(i,j,k,ioxygen)+bkoxamox))    &
                     &        * ocetra(i,j,k,ianh4)/(ocetra(i,j,k,ianh4)+bkamoxn2o)

            fno2     = ocetra(i,j,k,ioxygen)/(ocetra(i,j,k,ioxygen) + bkoxamox)
            fdetamox = n2omaxy*2._rp*(1._rp + n2oybeta)*ocetra(i,j,k,ioxygen)*bkyamox              &
                     & /(ocetra(i,j,k,ioxygen)**2 + 2._rp*ocetra(i,j,k,ioxygen)*bkyamox + bkyamox**2)

            ! normalization of pathway splitting functions to sum=1
            ftotnh4  = fn2o + fno2 + fdetamox + eps
            fn2o     = fn2o/ftotnh4
            fno2     = fno2/ftotnh4
            fdetamox = 1._rp - (fn2o + fno2)

            ! NO2 oxidizing step of nitrification
            Tdepano2    = q10ano2nitr**((temp-Trefano2nitr)/10._rp)
            O2limano2   = ocetra(i,j,k,ioxygen)/(ocetra(i,j,k,ioxygen) + bkoxnitr)
            nut2lim     = ocetra(i,j,k,iano2)/(ocetra(i,j,k,iano2) + bkano2nitr)
            ano2new     = ocetra(i,j,k,iano2)/(1._rp + rano2nitr*Tdepano2*O2limano2*nut2lim)
            potdno2nitr = max(0._rp,ocetra(i,j,k,iano2) - ano2new)

           ! pathway splitting functions for NO2 nitrification - assuming to be the same as for NH4
           ! but with reduced OM gain per used NO2 as energy source (in amox: NH4)
            no2fn2o     = mufn2o * (bn2o + (1._rp-bn2o)*bkoxamox/(ocetra(i,j,k,ioxygen)+bkoxamox)) &
                        &        * ocetra(i,j,k,ianh4)/(ocetra(i,j,k,ianh4)+bkamoxn2o)

            no2fno2     = ocetra(i,j,k,ioxygen)/(ocetra(i,j,k,ioxygen) + bkoxamox)
            no2fdetamox = NOB2AOAy*n2omaxy*2._rp*(1._rp + n2oybeta)*ocetra(i,j,k,ioxygen)*bkyamox  &
                        & /(ocetra(i,j,k,ioxygen)**2 + 2._rp*ocetra(i,j,k,ioxygen)*bkyamox + bkyamox**2)

            fdetnitr = no2fdetamox/(no2fno2 + no2fn2o + eps)   ! yield to energy usage ratio for NO2 -> ratio equals 16:x


          ! limitation of the two processes through available nutrients, etc.
            totd     = potdnh4amox + potdno2nitr
            amoxfrac = potdnh4amox/(totd + eps)
            nitrfrac = 1._rp - amoxfrac

            totd = max(0._rp,                                                                      &
                 &   min(totd,                                                                     &
                 &       max_limiter*ocetra(i,j,k,ianh4)/(amoxfrac + fdetnitr*nitrfrac + eps),     & ! ammonium
                 &       max_limiter*ocetra(i,j,k,isco212)/                                        &
                 &                             (rc2n*(fdetamox*amoxfrac + fdetnitr*nitrfrac) +eps),& ! CO2
                 &       max_limiter*ocetra(i,j,k,iphosph)/                                        &
                 &                             (rnoi*(fdetamox*amoxfrac + fdetnitr*nitrfrac) +eps),& ! PO4
                 &       max_limiter*ocetra(i,j,k,iiron)/                                          &
                 &              (riron*rnoi*(fdetamox*amoxfrac + fdetnitr*nitrfrac) + eps),        & ! Fe
                 &       max_limiter*ocetra(i,j,k,ioxygen)                                         &
                 &       /((1.5_rp*fno2 + fn2o - ro2nnit*fdetamox)*amoxfrac                        &
                                            + (0.5_rp - ro2nnit*fdetnitr)*nitrfrac + eps),         & ! O2
                 &       max_limiter*ocetra(i,j,k,ialkali)                                         &
                 &       /((2._rp*fno2 + fn2o + rnm1*rnoi*fdetamox)*amoxfrac                       &
                 &                         + (rnm1*rnoi*fdetnitr)*nitrfrac + eps)))                  ! alkalinity
            amox = amoxfrac*totd
            nitr = nitrfrac*totd

            ocetra(i,j,k,ianh4)   = ocetra(i,j,k,ianh4)   - amox - fdetnitr*nitr
            ocetra(i,j,k,ian2o)   = ocetra(i,j,k,ian2o)   + 0.5_rp*fn2o*amox
            ocetra(i,j,k,iano2)   = ocetra(i,j,k,iano2)   + fno2*amox - nitr
            ocetra(i,j,k,iano3)   = ocetra(i,j,k,iano3)   + nitr
            ocetra(i,j,k,idet)    = ocetra(i,j,k,idet)    + rnoi*(fdetamox*amox + fdetnitr*nitr)
            ocetra(i,j,k,isco212) = ocetra(i,j,k,isco212) - rc2n*(fdetamox*amox + fdetnitr*nitr)
            ocetra(i,j,k,iphosph) = ocetra(i,j,k,iphosph) - rnoi*(fdetamox*amox + fdetnitr*nitr)
            ocetra(i,j,k,iiron)   = ocetra(i,j,k,iiron)   - riron*rnoi*(fdetamox*amox + fdetnitr*nitr)
            ocetra(i,j,k,ioxygen) = ocetra(i,j,k,ioxygen) - (1.5_rp*fno2 + fn2o - ro2nnit*fdetamox)*amox &
                                  &                       - (0.5_rp - ro2nnit*fdetnitr)*nitr
            ocetra(i,j,k,ialkali) = ocetra(i,j,k,ialkali) - (2._rp*fno2 + fn2o + rnm1*rnoi*fdetamox)*amox&
                                  &                       - rnm1*rnoi*fdetnitr*nitr

            ! Output
            nitr_NH4(i,j,k)       = amox               ! kmol N/m3/dtb   - NH4 consumption for nitrification on NH4-incl. usage for biomass
            nitr_NO2(i,j,k)       = nitr               ! kmol N/m3/dtb   - NO2 consumption for nitrification on NO2
            nitr_N2O_prod(i,j,k)  = 0.5_rp*fn2o*amox   ! kmol N2O/m3/dtb - N2O production during aerob ammonium oxidation
            nitr_NH4_OM(i,j,k)    = rnoi*fdetamox*amox ! kmol P/m3/dtb   - organic matter production during aerob NH4 oxidation
            nitr_NO2_OM(i,j,k)    = rnoi*fdetnitr*nitr ! kmol P/m3/dtb   - organic matter production during aerob NO2 oxidation
          endif
        enddo
      enddo
    enddo
    !$OMP END PARALLEL DO
  end subroutine nitrification

!===================================================================================================================================
  subroutine denit_NO3_to_NO2(kpie,kpje,kpke,kbnd,pddpo,omask,ptho)
    ! Denitrification / dissimilatory nitrate reduction (NO3 -> NO2)

    integer, intent(in) :: kpie,kpje,kpke,kbnd
    real(rp),intent(in) :: omask(kpie,kpje)
    real(rp),intent(in) :: pddpo(kpie,kpje,kpke)
    real(rp),intent(in) :: ptho(1-kbnd:kpie+kbnd,1-kbnd:kpje+kbnd,kpke)

    !local variables
    integer :: i,j,k
    real(rp):: Tdep,O2inhib,nutlim,ano3new,ano3denit,temp

    ! Set output-related field to zero
    denit_NO3  = 0._rp

    !$OMP PARALLEL DO PRIVATE(i,k,Tdep,O2inhib,nutlim,ano3new,ano3denit,temp)
    do j = 1,kpje
      do i = 1,kpie
        do k = 1,kpke
          if(pddpo(i,j,k) > dp_min .and. omask(i,j) > 0.5_rp) then
            temp      = merge(ptho(i,j,k),10._rp,ptho(i,j,k) < 40._rp)
            Tdep      = q10ano3denit**((temp-Trefano3denit)/10._rp)
            O2inhib   = 1._rp - tanh(sc_ano3denit*ocetra(i,j,k,ioxygen))
            nutlim    = ocetra(i,j,k,iano3)/(ocetra(i,j,k,iano3) + bkano3denit)

            ano3new   = ocetra(i,j,k,iano3)/(1._rp + rano3denit*Tdep*O2inhib*nutlim)

            ano3denit = max(0._rp,min(ocetra(i,j,k,iano3) - ano3new,                               &
                                   max_limiter*ocetra(i,j,k,idet)*rnoxp))

            ocetra(i,j,k,iano3)   = ocetra(i,j,k,iano3)   - ano3denit
            ocetra(i,j,k,iano2)   = ocetra(i,j,k,iano2)   + ano3denit
            ocetra(i,j,k,idet)    = ocetra(i,j,k,idet)    - ano3denit*rnoxpi
            ocetra(i,j,k,ianh4)   = ocetra(i,j,k,ianh4)   + ano3denit*rnit*rnoxpi
            ocetra(i,j,k,isco212) = ocetra(i,j,k,isco212) + ano3denit*rcar*rnoxpi
            ocetra(i,j,k,iphosph) = ocetra(i,j,k,iphosph) + ano3denit*rnoxpi
            ocetra(i,j,k,iiron)   = ocetra(i,j,k,iiron)   + ano3denit*riron*rnoxpi
            ocetra(i,j,k,ialkali) = ocetra(i,j,k,ialkali) + ano3denit*rnm1*rnoxpi

            ! Output
            denit_NO3(i,j,k) = ano3denit ! kmol NO3/m3/dtb   - NO3 usage for denit on NO3
          endif
        enddo
      enddo
    enddo
    !$OMP END PARALLEL DO
  end subroutine denit_NO3_to_NO2

!==================================================================================================================================
  subroutine anammox(kpie,kpje,kpke,kbnd,pddpo,omask,ptho)
    ! Aanammox

    integer, intent(in) :: kpie,kpje,kpke,kbnd
    real(rp),intent(in) :: omask(kpie,kpje)
    real(rp),intent(in) :: pddpo(kpie,kpje,kpke)
    real(rp),intent(in) :: ptho(1-kbnd:kpie+kbnd,1-kbnd:kpje+kbnd,kpke)

    !local variables
    integer :: i,j,k
    real(rp):: Tdep,O2inhib,nut1lim,nut2lim,ano2new,ano2anmx,temp

    ! Set output-related field to zero
    anmx_N2_prod = 0._rp
    anmx_OM_prod = 0._rp

    !$OMP PARALLEL DO PRIVATE(i,k,Tdep,O2inhib,nut1lim,nut2lim,ano2new,ano2anmx,temp)
    do j = 1,kpje
      do i = 1,kpie
        do k = 1,kpke
          if(pddpo(i,j,k) > dp_min .and. omask(i,j) > 0.5_rp) then
            temp     = merge(ptho(i,j,k),10._rp,ptho(i,j,k) < 40._rp)
            Tdep     = q10anmx**((temp-Trefanmx)/10._rp)
            O2inhib  = 1._rp - exp(alphaanmx*(ocetra(i,j,k,ioxygen)-bkoxanmx))                     &
                     &     /(1._rp+ exp(alphaanmx*(ocetra(i,j,k,ioxygen)-bkoxanmx)))
            nut1lim  = ocetra(i,j,k,iano2)/(ocetra(i,j,k,iano2)+bkano2anmx)
            nut2lim  = ocetra(i,j,k,ianh4)/(ocetra(i,j,k,ianh4)+bkanh4anmx)

            ano2new  = ocetra(i,j,k,iano2)/(1._rp + rano2anmx*Tdep*O2inhib*nut1lim*nut2lim)

            ano2anmx = max(0._rp,min(ocetra(i,j,k,iano2) - ano2new,                                &
                                  max_limiter*ocetra(i,j,k,ianh4)*rno2anmx*rnh4anmxi,              &
                                  max_limiter*ocetra(i,j,k,isco212)*rno2anmx/rcar,                 &
                                  max_limiter*ocetra(i,j,k,iphosph)*rno2anmx,                      &
                                  max_limiter*ocetra(i,j,k,iiron)*rno2anmx/riron,                  &
                                  max_limiter*ocetra(i,j,k,ialkali)*rno2anmx/rnm1))

            ocetra(i,j,k,iano2)   = ocetra(i,j,k,iano2)   - ano2anmx
            ocetra(i,j,k,ianh4)   = ocetra(i,j,k,ianh4)   - ano2anmx*rnh4anmx*rno2anmxi
            ocetra(i,j,k,igasnit) = ocetra(i,j,k,igasnit) + ano2anmx*(rnh4anmx-rnit)*rno2anmxi
            ocetra(i,j,k,iano3)   = ocetra(i,j,k,iano3)   + ano2anmx*rnoxp*rno2anmxi
            ocetra(i,j,k,idet)    = ocetra(i,j,k,idet)    + ano2anmx*rno2anmxi
            ocetra(i,j,k,isco212) = ocetra(i,j,k,isco212) - ano2anmx*rcar*rno2anmxi
            ocetra(i,j,k,iphosph) = ocetra(i,j,k,iphosph) - ano2anmx*rno2anmxi
            ocetra(i,j,k,iiron)   = ocetra(i,j,k,iiron)   - ano2anmx*riron*rno2anmxi
            ocetra(i,j,k,ialkali) = ocetra(i,j,k,ialkali) - ano2anmx*rnm1*rno2anmxi

            ! Output
            anmx_N2_prod(i,j,k) = ano2anmx*(rnh4anmx-rnit)*rno2anmxi  ! kmol N2/m3/dtb - N2 prod through anammox
            anmx_OM_prod(i,j,k) = ano2anmx*rno2anmxi                  ! kmol P/m3/dtb  - OM production by anammox
          endif
        enddo
      enddo
    enddo
    !$OMP END PARALLEL DO
  end subroutine anammox

!==================================================================================================================================
  subroutine denit_dnra(kpie,kpje,kpke,kbnd,pddpo,omask,ptho)
    ! Denitrification processes (NO2 -> N2O -> N2) and dissmilatory nitrite reduction (NO2 -> NH4)

    integer, intent(in) :: kpie,kpje,kpke,kbnd
    real(rp),intent(in) :: omask(kpie,kpje)
    real(rp),intent(in) :: pddpo(kpie,kpje,kpke)
    real(rp),intent(in) :: ptho(1-kbnd:kpie+kbnd,1-kbnd:kpje+kbnd,kpke)

    !local variables
    integer  :: i,j,k
    real(rp) :: Tdepano2,O2inhibano2,nutlimano2,detlimano2,rpotano2denit,ano2denit
    real(rp) :: Tdepdnra,O2inhibdnra,nutlimdnra,detlimdnra,rpotano2dnra,ano2dnra
    real(rp) :: fdenit,fdnra,potano2new,potdano2,potddet,fdetano2denit,fdetan2odenit,fdetdnra
    real(rp) :: Tdepan2o,O2inhiban2o,nutliman2o,detliman2o,an2onew,an2odenit

    real(rp) :: temp

    ! Set output-related field to zero
    denit_NO2 = 0._rp
    denit_N2O = 0._rp
    DNRA_NO2  = 0._rp

    !$OMP PARALLEL DO PRIVATE(i,k,Tdepano2,O2inhibano2,nutlimano2,detlimano2,ano2denit,            &
    !$OMP                     Tdepan2o,O2inhiban2o,nutliman2o,detliman2o,an2onew,an2odenit,        &
    !$OMP                     rpotano2denit,rpotano2dnra,                                          &
    !$OMP                     fdenit,fdnra,potano2new,potdano2,potddet,fdetano2denit,              &
    !$OMP                     fdetan2odenit,fdetdnra,                                              &
    !$OMP                     Tdepdnra,O2inhibdnra,nutlimdnra,detlimdnra,ano2dnra,temp)

    do j = 1,kpje
      do i = 1,kpie
        do k = 1,kpke
          if(pddpo(i,j,k) > dp_min .and. omask(i,j) > 0.5_rp) then
            potddet       = 0._rp
            an2odenit     = 0._rp
            ano2denit     = 0._rp
            ano2dnra      = 0._rp

            temp = merge(ptho(i,j,k),10._rp,ptho(i,j,k) < 40._rp)
            ! === denitrification on N2O
            Tdepan2o    = q10an2odenit**((temp-Trefan2odenit)/10._rp)
            O2inhiban2o = bkoxan2odenit**2/(ocetra(i,j,k,ioxygen)**2 + bkoxan2odenit**2)
            nutliman2o  = ocetra(i,j,k,ian2o)/(ocetra(i,j,k,ian2o) + bkan2odenit)
            an2onew     = ocetra(i,j,k,ian2o)/(1._rp + ran2odenit*Tdepan2o*O2inhiban2o*nutliman2o)
            an2odenit   = max(0._rp,min(ocetra(i,j,k,ian2o),ocetra(i,j,k,ian2o) - an2onew))

            ! denitrification on NO2
            Tdepano2    =  q10ano2denit**((temp-Trefano2denit)/10._rp)
            O2inhibano2 = bkoxano2denit**2/(ocetra(i,j,k,ioxygen)**2 + bkoxano2denit**2)
            nutlimano2  = ocetra(i,j,k,iano2)/(ocetra(i,j,k,iano2) + bkano2denit)
            rpotano2denit = max(0._rp,rano2denit*Tdepano2*O2inhibano2*nutlimano2) ! potential rate of denit

            ! DNRA on NO2
            Tdepdnra    = q10dnra**((temp-Trefdnra)/10._rp)
            O2inhibdnra = bkoxdnra**2/(ocetra(i,j,k,ioxygen)**2 + bkoxdnra**2)
            nutlimdnra  = ocetra(i,j,k,iano2)/(ocetra(i,j,k,iano2) + bkdnra)
            rpotano2dnra = max(0._rp,rdnra*Tdepdnra*O2inhibdnra*nutlimdnra) ! pot. rate of dnra

            ! potential new conc of NO2 due to denitrification and DNRA
            potano2new = ocetra(i,j,k,iano2)/(1._rp + rpotano2denit + rpotano2dnra)
            potdano2   = max(0._rp,min(ocetra(i,j,k,iano2), ocetra(i,j,k,iano2) - potano2new))

            ! === limitation due to NO2:
            ! fraction on potential change of NO2:
            fdenit = rpotano2denit/(rpotano2denit + rpotano2dnra + eps)
            fdnra  = 1._rp - fdenit

            ! potential fractional change
            ano2denit  = fdenit * potdano2
            ano2dnra   = fdnra  * potdano2

            ! limitation of processes due to detritus
            potddet       = rnoxpi*(ano2denit + an2odenit) + rno2dnrai*ano2dnra  ! P units
            fdetano2denit = rnoxpi*ano2denit/(potddet + eps)
            fdetan2odenit = rnoxpi*an2odenit/(potddet + eps)
            fdetdnra      = 1._rp - fdetano2denit - fdetan2odenit
            potddet       = max(0._rp,min(potddet,max_limiter*ocetra(i,j,k,idet)))

            ! change of NO2 and N2O in N units
            ano2denit     = fdetano2denit*rnoxp*potddet
            an2odenit     = fdetan2odenit*rnoxp*potddet
            ano2dnra      = fdetdnra*rno2dnra*potddet

            ! change in tracer concentrations due to denit (NO2->N2O->N2) and DNRA (NO2->NH4)
            ocetra(i,j,k,iano2)   = ocetra(i,j,k,iano2)   - ano2denit - ano2dnra
            ocetra(i,j,k,ian2o)   = ocetra(i,j,k,ian2o)   - an2odenit + 0.5_rp*ano2denit
            ocetra(i,j,k,igasnit) = ocetra(i,j,k,igasnit) + an2odenit
            ocetra(i,j,k,ianh4)   = ocetra(i,j,k,ianh4)   + rnit*rnoxpi*(ano2denit+an2odenit)      &
                                  &                       + rnh4dnra*rno2dnrai*ano2dnra
            ocetra(i,j,k,idet)    = ocetra(i,j,k,idet)    - (ano2denit + an2odenit)*rnoxpi         &
                                  &                       - ano2dnra*rno2dnrai
            ocetra(i,j,k,isco212) = ocetra(i,j,k,isco212) + rcar*rnoxpi*(ano2denit + an2odenit)    &
                                  &                       + rcar*rno2dnrai*ano2dnra
            ocetra(i,j,k,iphosph) = ocetra(i,j,k,iphosph) + (ano2denit + an2odenit)*rnoxpi         &
                                  &                       + ano2dnra*rno2dnrai
            ocetra(i,j,k,iiron)   = ocetra(i,j,k,iiron)   + riron*rnoxpi*(ano2denit + an2odenit)   &
                                  &                       + riron*rno2dnrai*ano2dnra
            ocetra(i,j,k,ialkali) = ocetra(i,j,k,ialkali) + (295._rp*ano2denit + rnm1*an2odenit)*rnoxpi &
                                 &                        + (rno2dnra + rnh4dnra - 1._rp)*rno2dnrai*ano2dnra
            ! Output
            denit_NO2(i,j,k) = ano2denit ! kmol NO2/m3/dtb - denitrification on NO2
            denit_N2O(i,j,k) = an2odenit ! kmol N2O/m3/dtb - denitrification on N2O
            DNRA_NO2(i,j,k)  = ano2dnra  ! kmol NO2/m3/dtb - DNRA on NO2
          endif
        enddo
      enddo
    enddo
    !$OMP END PARALLEL DO
  end subroutine denit_dnra



!==================================================================================================================================
  subroutine extN_inv_check(kpie,kpje,kpke,pdlxp,pdlyp,pddpo,omask,inv_message)
    use mo_inventory_bgc, only: inventory_bgc
    use mo_control_bgc,   only: io_stdo_bgc,use_PBGC_OCNP_TIMESTEP

    implicit none
    ! provide inventory calculation for extended nitrogen cycle

    integer, intent(in) :: kpie,kpje,kpke
    real(rp),intent(in) :: omask(kpie,kpje)
    real(rp),intent(in) :: pdlxp(kpie,kpje),pdlyp(kpie,kpje),pddpo(kpie,kpje,kpke)
    character (len=*),intent(in) :: inv_message

    if (use_PBGC_OCNP_TIMESTEP) then
      if (mnproc == 1) then
        write(io_stdo_bgc,*)' '
        write(io_stdo_bgc,*)inv_message
      endif
      call INVENTORY_BGC(kpie,kpje,kpke,pdlxp,pdlyp,pddpo,omask,0)
    endif
  end subroutine extN_inv_check

!==================================================================================================================================
end module mo_extNwatercol
