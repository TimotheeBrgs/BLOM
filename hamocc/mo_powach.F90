! Copyright (C) 2001  Ernst Maier-Reimer, S. Legutke
! Copyright (C) 2020  K. Assmann, J. Tjiputra, J. Schwinger
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

module mo_powach

  implicit none
  private

  public :: powach

contains

  subroutine powach(kpie,kpje,kpke,kbnd,prho,omask,psao,ptho,lspin)

    !***********************************************************************************************
    ! Ernst Maier-Reimer,    *MPI-Met, HH*    10.04.01
    ! Modified: S.Legutke,   *MPI-MaD, HH*    10.04.01
    !***********************************************************************************************

    use mo_kind,        only: rp
    use mo_control_bgc, only: dtbgc,use_cisonew,use_extNcycle,lTO2depremin,use_sediment_quality,   &
                            & ldyn_sed_age
    use mo_param1_bgc,  only: ioxygen,ipowaal,ipowaic,ipowaox,ipowaph,ipowasi,ipown2,ipowno3,      &
                              isilica,isssc12,issso12,issssil,issster,ks,ipowc13,ipowc14,isssc13,  &
                              isssc14,issso13,issso14,safediv,ipownh4,issso12_age
    use mo_carbch,      only: co3,keqb,ocetra,sedfluxo,sedfluxb
    use mo_chemcon,     only: calcon
    use mo_param_bgc,   only: rnit,rcar,rdnit1,rdnit2,ro2ut,disso_sil,silsat,disso_poc,sed_denit,  &
                            & disso_caco3,ro2utammo,sed_alpha_poc,sed_sulf,                        &
                            & POM_remin_q10_sed,POM_remin_Tref_sed,bkox_drempoc_sed,sed_qual_sc,   &
                            & sec_per_year,sec_per_day,sed_O2thresh_hypoxic,sed_O2thresh_sulf,     &
                            & sed_NO3thresh_sulf
    use mo_sedmnt,      only: porwat,porsol,powtra,produs,prcaca,prorca,seddw,sedhpl,sedlay,       &
                              silpro,pror13,pror14,prca13,prca14,prorca_mavg,sed_reactivity_a,     &
                              sed_reactivity_k,sed_applied_reminrate,                              &
                              sed_rem_aerob,sed_rem_denit,sed_rem_sulf
    use mo_vgrid,       only: kbo,bolay
    use mo_powadi,      only: powadi
    use mo_carchm,      only: carchm_solve
    use mo_dipowa,      only: dipowa
    use mo_extNsediment,only: sed_nitrification,sed_denit_NO3_to_NO2,sed_anammox,sed_denit_DNRA,   &
                            & extNsed_diagnostics,ised_remin_aerob,ised_remin_sulf

    ! Arguments
    integer, intent(in) :: kpie                                         ! 1st dimension of model grid.
    integer, intent(in) :: kpje                                         ! 2nd dimension of model grid.
    integer, intent(in) :: kpke                                         ! 3rd (vertical) dimension of model grid.
    integer, intent(in) :: kbnd                                         ! nb of halo grid points
    real(rp),intent(in) :: prho(kpie,kpje,kpke)                         ! seawater density [g/cm^3].
    real(rp),intent(in) :: omask(kpie,kpje)                             ! land/ocean mask.
    real(rp),intent(in) :: psao(1-kbnd:kpie+kbnd,1-kbnd:kpje+kbnd,kpke) ! salinity [psu].
    real(rp),intent(in) :: ptho(1-kbnd:kpie+kbnd,1-kbnd:kpje+kbnd,kpke) ! Pot. temperature [deg C].
    logical, intent(in) :: lspin

    ! Local variables
    integer  :: i,j,k,l
    real(rp) :: sedb1(kpie,0:ks),sediso(kpie,0:ks)
    real(rp) :: solrat(kpie,ks),powcar(kpie,ks)
    real(rp) :: aerob(kpie,ks),anaerob(kpie,ks),sulf(kpie,ks)
    real(rp) :: ex_ddic(kpie,ks),ex_dalk(kpie,ks) !sum of DIC and alk changes related to extended nitrogen cycle
    real(rp) :: ex_disso_poc
    real(rp) :: aerob13(kpie,ks),anaerob13(kpie,ks),sulf13(kpie,ks) ! cisonew
    real(rp) :: aerob14(kpie,ks),anaerob14(kpie,ks),sulf14(kpie,ks) ! cisonew
    real(rp) :: dissot, undsa, posol
    real(rp) :: umfa, denit, rrho, alk, c, sit, pt
    real(rp) :: K1, K2, Kb, Kw, Ks1, Kf, Ksi, K1p, K2p, K3p
    real(rp) :: ah1, ac, cu, cb, cc, satlev
    real(rp) :: ratc13, ratc14, rato13, rato14, poso13, poso14
    real(rp) :: avgDOU
    real(rp) :: eps=epsilon(1._rp)

    ! Set array for saving diffusive sediment-water-column fluxes to zero
    !********************************************************************
    sedfluxo(:,:,:) = 0.0_rp

    ! set other sediment diagnostic variables to zero
    sedfluxb(:,:,:) = 0.0_rp
    if (use_extNcycle) then
      extNsed_diagnostics(:,:,:,:) = 0.0_rp
    else
      sed_rem_aerob(:,:,:) = 0._rp
      sed_rem_denit(:,:,:) = 0._rp
      sed_rem_sulf(:,:,:)  = 0._rp
    endif

    ! A LOOP OVER J
    ! RJ: This loop must go from 1 to kpje in the parallel version,
    !     otherways we had to do a boundary exchange

    !$OMP  PARALLEL DO                                                      &
    !$OMP& PRIVATE(sedb1,sediso,solrat,powcar,aerob,anaerob,                &
    !$OMP&         ex_dalk,ex_ddic,ex_disso_poc,                            &
    !$OMP&         dissot,undsa,posol,                                      &
    !$OMP&         umfa,denit,rrho,alk,c,sit,pt,                            &
    !$OMP&         K1,K2,Kb,Kw,Ks1,Kf,Ksi,K1p,K2p,K3p,                      &
    !$OMP&         ah1,ac,cu,cb,cc,satlev,                                  &
    !$OMP&         ratc13,ratc14,rato13,rato14,poso13,poso14,               &
    !$OMP&         k,i,avgDOU)

    j_loop: do j = 1, kpje

      do k = 1, ks
        do i = 1, kpie
          solrat(i,k) = 0._rp
          powcar(i,k) = 0._rp
          if  (use_extNcycle) then
            ex_ddic(i,k) = 0._rp
            ex_dalk(i,k) = 0._rp
          else
            anaerob(i,k) = 0._rp
          endif
          aerob(i,k)  = 0._rp
          sulf(i,k)   = 0._rp
          if (use_cisonew) then
            anaerob13(i,k)=0._rp
            aerob13(i,k)  =0._rp
            sulf13(i,k)   =0._rp
            anaerob14(i,k)=0._rp
            aerob14(i,k)  =0._rp
            sulf14(i,k)   =0._rp
          endif
        enddo
      enddo

      do k = 0, ks
        do i = 1, kpie
          sedb1(i,k) = 0._rp
          sediso(i,k) = 0._rp
        enddo
      enddo

      ! Calculate silicate-opal cycle and simultaneous silicate diffusion
      !******************************************************************

      ! Dissolution rate constant of opal (disso) [1/(kmol Si(OH)4/m3)*1/sec]*dtbgc
      dissot=disso_sil

      ! Evaluate boundary conditions for sediment-water column exchange.
      ! Current undersaturation of bottom water: sedb(i,0) and
      ! Approximation for new solid sediment, as from sedimentation flux: solrat(i,1)

      do i = 1, kpie
        if(omask(i,j) > 0.5_rp) then
          undsa = silsat - powtra(i,j,1,ipowasi)
          sedb1(i,0) = bolay(i,j) * (silsat - ocetra(i,j,kbo(i,j),isilica))
          solrat(i,1) = ( sedlay(i,j,1,issssil)                                                    &
               + silpro(i,j) / (porsol(i,j,1) * seddw(1)) )                                        &
               * dissot / (1._rp + dissot * undsa) * porsol(i,j,1) / porwat(i,j,1)
        endif
      enddo

      ! Evaluate sediment undersaturation and degradation.
      ! Current undersaturation in pore water: sedb(i,k) and
      ! Approximation for new solid sediment, as from degradation: solrat(i,k)

      do k = 1, ks
        do i = 1, kpie
          if(omask(i,j) > 0.5_rp) then
            undsa = silsat - powtra(i,j,k,ipowasi)
            sedb1(i,k) = seddw(k) * porwat(i,j,k) * (silsat - powtra(i,j,k,ipowasi))
            if ( k > 1 ) solrat(i,k) = sedlay(i,j,k,issssil)                                       &
                 * dissot / (1._rp + dissot * undsa) * porsol(i,j,k) / porwat(i,j,k)
          endif
        enddo
      enddo

      ! Solve for new undersaturation sediso, from current undersaturation sedb1,
      ! and first guess of new solid sediment solrat.

      call powadi(j,kpie,kpje,solrat,sedb1,sediso,omask)

      ! Update water column silicate, and store the flux for budget.
      ! Add sedimentation to first layer.

      do i = 1, kpie
        if(omask(i,j) > 0.5_rp) then
          if(.not. lspin) then
            sedfluxo(i,j,ipowasi) =                                                                &
                 -(silsat - sediso(i,0) - ocetra(i,j,kbo(i,j),isilica))                            &
                 * bolay(i,j)
            ocetra(i,j,kbo(i,j),isilica) = silsat - sediso(i,0)
          endif
          sedlay(i,j,1,issssil) =                                                                  &
               sedlay(i,j,1,issssil) + silpro(i,j) / (porsol(i,j,1) * seddw(1))
        endif
      enddo


      ! Calculate updated degradation rate from updated undersaturation.
      ! Calculate new solid sediment.
      ! Update pore water concentration from new undersaturation.

      do k = 1, ks
        do i = 1, kpie
          if(omask(i,j) > 0.5_rp) then
            umfa = porsol(i,j,k)/porwat(i,j,k)
            solrat(i,k) = sedlay(i,j,k,issssil) * dissot / (1._rp + dissot * sediso(i,k))
            posol = sediso(i,k) * solrat(i,k)
            sedlay(i,j,k,issssil) = sedlay(i,j,k,issssil) - posol
            powtra(i,j,k,ipowasi) = silsat - sediso(i,k)
          endif
        enddo
      enddo

      ! Pre-calculate sediment POC age and prorca-moving average
      ! to enable sediment quality-POC remineralization in sediment according to
      ! Pika et al. 2023: Regional and global patterns of apparent organic matter
      !                   reactivity in marine sediments. Global Biogeochemical Cycles 37,
      !                   https://doi.org/10.1029/2022GB007636
      if (use_sediment_quality) then
        do i = 1, kpie
          if (omask(i,j) > 0.5_rp ) then
            ! Update moving average TOC flux to bottom
            ! units of prorca: kmol P/m2/dt -> prorca_mavg in mmol P/m2/d
            prorca_mavg(i,j) = sed_alpha_poc*prorca(i,j)*1.e6_rp*dtbgc/sec_per_day                 &
                             & + (1._rp-sed_alpha_poc)*prorca_mavg(i,j)
            if (ldyn_sed_age) then
              ! update surface age due to fresh POC sedimentation flux
              sedlay(i,j,1,issso12_age) = sedlay(i,j,1,issso12) * sedlay(i,j,1,issso12_age)        &
                          & / ((prorca(i,j)/(porsol(i,j,1)*seddw(1))) + sedlay(i,j,1,issso12) + eps)
            endif
            do k = 1, ks
              if (ldyn_sed_age) then
                ! Update sediment POC age [yrs]
                sedlay(i,j,k,issso12_age) = sedlay(i,j,k,issso12_age) + dtbgc/sec_per_year
              endif
              ! Mean DOU flux [mmol O2/m2/d]
              ! Since reactivity is based on total sediment DOU (incl. nitrification),
              ! we here assume the full oxydation steo and use ro2ut
              avgDOU                    = max(eps,prorca_mavg(i,j)*ro2ut)
              ! Eq.(12) in Pika et al. 2023 * correction factor 2.48 = a (sed reactivity)
              sed_reactivity_a(i,j,k)   = 2.48_rp * 10._rp**(1.293_rp - 0.9822_rp*log10(avgDOU))
              ! Calculating overall (scaled) reactivity k [1/year] -> [1/(kmol O2/m3 dt)]
              ! using 1mumol O2/m3 (=1e-6 kmol O2/m3) as reference
              sed_reactivity_k(i,j,k)   = sed_qual_sc*dtbgc/(sec_per_year*1.e-6_rp)*0.151_rp       &
                                        & /(sed_reactivity_a(i,j,k) + sedlay(i,j,k,issso12_age)+eps)
            enddo
          endif
        enddo
      endif

      ! Calculate oxygen-POC cycle and simultaneous oxygen diffusion
      !*************************************************************

      ! Degradation rate constant of POP (disso) [1/(kmol O2/m3)*1/sec]*dtbgc
      dissot = disso_poc

      ! This scheme is not based on undersaturation, but on O2 itself

      ! Evaluate boundary conditions for sediment-water column exchange.
      ! Current concentration of bottom water: sedb(i,0) and
      ! Approximation for new solid sediment, as from sedimentation flux: solrat(i,1)

      do i = 1, kpie
        if(omask(i,j) > 0.5_rp) then
          undsa = powtra(i,j,1,ipowaox)
          sedb1(i,0) = bolay(i,j) * ocetra(i,j,kbo(i,j),ioxygen)
          if (use_sediment_quality) then
            dissot = sed_reactivity_k(i,j,1)
          endif
          ex_disso_poc=merge(dissot*powtra(i,j,1,ipowaox)/(powtra(i,j,1,ipowaox)+bkox_drempoc_sed) & ! oxygen limitation
                         &    *POM_remin_q10_sed**((ptho(i,j,kbo(i,j))-POM_remin_Tref_sed)/10._rp) & ! T-dep
                         &   ,dissot,lTO2depremin)
          if ( .not.  use_extNcycle) then
            solrat(i,1) = ( sedlay(i,j,1,issso12) + prorca(i,j)                                    &
                        &  / (porsol(i,j,1) * seddw(1)) )                                          &
                        &   * ro2ut * ex_disso_poc / (1._rp + ex_disso_poc * undsa)                &
                        &   * porsol(i,j,1) / porwat(i,j,1)
          else
            ! extended nitrogen cycle - 140mol O2/mol POP O2-consumption
            ! O2 and T-dep
            solrat(i,1) = ( sedlay(i,j,1,issso12) + prorca(i,j)                                    &
                        & / (porsol(i,j,1) * seddw(1)) )                                           &
                        & * ro2utammo * ex_disso_poc / (1._rp + ex_disso_poc * undsa)              &
                        & * porsol(i,j,1) / porwat(i,j,1)
          endif
        endif
      enddo

      ! Evaluate sediment concentration and degradation.
      ! Current concentration in pore water: sedb(i,k) and
      ! Approximation for new solid sediment, as from degradation: solrat(i,k)

      do k = 1, ks
        do i = 1, kpie
          if(omask(i,j) > 0.5_rp) then
            undsa = powtra(i,j,k,ipowaox)
            sedb1(i,k) = seddw(k) * porwat(i,j,k) * powtra(i,j,k,ipowaox)
            if (use_sediment_quality) then
              dissot = sed_reactivity_k(i,j,k)
            endif
            ex_disso_poc=merge(dissot*powtra(i,j,k,ipowaox)/(powtra(i,j,k,ipowaox)+bkox_drempoc_sed) & ! oxygen limitation
                         &      *POM_remin_q10_sed**((ptho(i,j,kbo(i,j))-POM_remin_Tref_sed)/10._rp) & ! T-dep
                         &   ,dissot,lTO2depremin)
            if ( .not. use_extNcycle) then
              if (k > 1) solrat(i,k) = sedlay(i,j,k,issso12) * ro2ut * ex_disso_poc                &
                                     & / (1._rp + ex_disso_poc*undsa) * porsol(i,j,k) / porwat(i,j,k)
            else
              ! extended nitrogen cycle - 140mol O2/mol POP O2-consumption
              if (k > 1) solrat(i,k) = sedlay(i,j,k,issso12) * ro2utammo * ex_disso_poc            &
                                     & /(1._rp + ex_disso_poc*undsa) * porsol(i,j,k) / porwat(i,j,k)
            endif
          endif
        enddo
      enddo

      ! Solve for new O2 concentration sediso, from current concentration sedb1,
      ! and first guess of new solid sediment solrat.

      call powadi(j,kpie,kpje,solrat,sedb1,sediso,omask)

      ! Update water column oxygen, and store the diffusive flux for budget (sedfluxo,
      ! positive downward). Add sedimentation to first layer.

      do i = 1, kpie
        if(omask(i,j) > 0.5_rp) then
          if(.not. lspin) then
            sedfluxo(i,j,ipowaox) = -(sediso(i,0) - ocetra(i,j,kbo(i,j),ioxygen)) * bolay(i,j)
            ocetra(i,j,kbo(i,j),ioxygen) = sediso(i,0)
          endif
          sedlay(i,j,1,issso12) = sedlay(i,j,1,issso12) + prorca(i,j) / (porsol(i,j,1)*seddw(1))
          if (use_cisonew) then
            sedlay(i,j,1,issso13) = sedlay(i,j,1,issso13) + pror13(i,j) / (porsol(i,j,1)*seddw(1))
            sedlay(i,j,1,issso14) = sedlay(i,j,1,issso14) + pror14(i,j) / (porsol(i,j,1)*seddw(1))
          endif
        endif
      enddo


      ! Calculate updated degradation rate from updated concentration.
      ! Calculate new solid sediment.
      ! Update pore water concentration.
      ! Store flux in array aerob, for later computation of DIC and alkalinity.
      do k = 1, ks
        do i = 1, kpie
          if(omask(i,j) > 0.5_rp) then
            umfa = porsol(i,j,k) / porwat(i,j,k)
            if (use_sediment_quality) then
              dissot = sed_reactivity_k(i,j,k)
            endif
            ex_disso_poc=merge(dissot*powtra(i,j,k,ipowaox)/(powtra(i,j,k,ipowaox)+bkox_drempoc_sed) & ! oxygen limitation
                         &      *POM_remin_q10_sed**((ptho(i,j,kbo(i,j))-POM_remin_Tref_sed)/10._rp) & ! T-dep
                         &   ,dissot,lTO2depremin)
            if (.not. use_extNcycle) then
              solrat(i,k) = sedlay(i,j,k,issso12) * ex_disso_poc/(1._rp + ex_disso_poc*sediso(i,k))
            else
              solrat(i,k) = sedlay(i,j,k,issso12) * ex_disso_poc/(1._rp + ex_disso_poc*sediso(i,k))
            endif
            posol = sediso(i,k)*solrat(i,k)
            if (use_cisonew) then
              rato13 = sedlay(i,j,k,issso13) / (sedlay(i,j,k,issso12) + safediv)
              rato14 = sedlay(i,j,k,issso14) / (sedlay(i,j,k,issso12) + safediv)
              poso13 = posol*rato13
              poso14 = posol*rato14
              aerob13(i,k) = poso13*umfa  !this has P units: kmol P/m3 of pore water
              aerob14(i,k) = poso14*umfa  !this has P units: kmol P/m3 of pore water
            endif
            sedlay(i,j,k,issso12) = sedlay(i,j,k,issso12) - posol
            powtra(i,j,k,ipowaph) = powtra(i,j,k,ipowaph) + posol*umfa
            if (.not. use_extNcycle) then
              powtra(i,j,k,ipowno3) = powtra(i,j,k,ipowno3) + posol*rnit*umfa
              aerob(i,k) = posol*umfa     !this has P units: kmol P/m3 of pore water
              sed_rem_aerob(i,j,k) = posol*umfa ! Output
            else
              powtra(i,j,k,ipownh4) = powtra(i,j,k,ipownh4) + posol*rnit*umfa
              ex_ddic(i,k) = rcar*posol*umfa ! C-units kmol C/m3 of pore water
              ex_dalk(i,k) = (rnit-1._rp)*posol*umfa ! alkalinity units
              extNsed_diagnostics(i,j,k,ised_remin_aerob) = posol*rnit*umfa ! Output
            endif
            powtra(i,j,k,ipowaox) = sediso(i,k)
            if (use_cisonew) then
              sedlay(i,j,k,issso13) = sedlay(i,j,k,issso13) - poso13
              sedlay(i,j,k,issso14) = sedlay(i,j,k,issso14) - poso14
            endif
            if (use_sediment_quality) then
              sed_applied_reminrate(i,j,k) = ex_disso_poc
            endif
          endif
        enddo
      enddo

      ! Calculate nitrate reduction under anaerobic conditions explicitely
      !*******************************************************************
      ! Denitrification rate constant of POP (disso) [1/sec]*dtbgc
      denit = sed_denit
      if (.not. use_extNcycle) then
        ! Store flux in array anaerob, for later computation of DIC and alkalinity.
        do k = 1, ks
          do i = 1, kpie
            if(omask(i,j) > 0.5_rp) then
              if(powtra(i,j,k,ipowaox) < sed_O2thresh_hypoxic) then
                posol = denit * min(0.25_rp*powtra(i,j,k,ipowno3)/rdnit2, sedlay(i,j,k,issso12))
                umfa = porsol(i,j,k)/porwat(i,j,k)
                anaerob(i,k) = posol*umfa     !this has P units: kmol P/m3 of pore water
                if (use_cisonew) then
                  rato13 = sedlay(i,j,k,issso13) / (sedlay(i,j,k,issso12) + safediv)
                  rato14 = sedlay(i,j,k,issso14) / (sedlay(i,j,k,issso12) + safediv)
                  poso13 = posol * rato13
                  poso14 = posol * rato14
                  anaerob13(i,k) = poso13*umfa  !this has P units: kmol P/m3 of pore water
                  anaerob14(i,k) = poso14*umfa  !this has P units: kmol P/m3 of pore water
                endif
                sedlay(i,j,k,issso12) = sedlay(i,j,k,issso12) - posol
                powtra(i,j,k,ipowaph) = powtra(i,j,k,ipowaph) + posol*umfa
                powtra(i,j,k,ipowno3) = powtra(i,j,k,ipowno3) - rdnit1*posol*umfa
                powtra(i,j,k,ipown2)  = powtra(i,j,k,ipown2)  + rdnit2*posol*umfa
                if (use_cisonew) then
                  sedlay(i,j,k,issso13) = sedlay(i,j,k,issso13) - poso13
                  sedlay(i,j,k,issso14) = sedlay(i,j,k,issso14) - poso14
                endif
                sed_rem_denit(i,j,k) = posol * umfa
              endif
            endif
          enddo
        enddo
      else
        !======>>>> extended nitrogen cycle processes (aerobic and anaerobic) that follow ammonification
        call sed_nitrification(j,kpie,kpje,kpke,kbnd,ptho,omask,ex_ddic,ex_dalk)
        call sed_denit_NO3_to_NO2(j,kpie,kpje,kpke,kbnd,ptho,omask,ex_ddic,ex_dalk)
        call sed_anammox(j,kpie,kpje,kpke,kbnd,ptho,omask,ex_ddic,ex_dalk)
        call sed_denit_dnra(j,kpie,kpje,kpke,kbnd,ptho,omask,ex_ddic,ex_dalk)
      endif

      ! sulphate reduction in sediments
      do k = 1, ks
        do i = 1, kpie
          if(omask(i,j) > 0.5_rp) then
            if(powtra(i,j,k,ipowaox) < sed_O2thresh_sulf .and. powtra(i,j,k,ipowno3) < sed_NO3thresh_sulf) then
              posol = sed_sulf * sedlay(i,j,k,issso12)         ! remineralization of poc
              umfa = porsol(i,j,k) / porwat(i,j,k)
              sulf(i,k) = posol*umfa      !this has P units: kmol P/m3 of pore water
              if (use_cisonew) then
                rato13 = sedlay(i,j,k,issso13) / (sedlay(i,j,k,issso12)+safediv)
                rato14 = sedlay(i,j,k,issso14) / (sedlay(i,j,k,issso12)+safediv)
                poso13 = posol * rato13
                poso14 = posol * rato14
                sulf13(i,k) = poso13*umfa !this has P units: kmol P/m3 of pore water
                sulf14(i,k) = poso14*umfa !this has P units: kmol P/m3 of pore water
              endif
              sedlay(i,j,k,issso12) = sedlay(i,j,k,issso12) - posol
              powtra(i,j,k,ipowaph) = powtra(i,j,k,ipowaph) + posol*umfa
              powtra(i,j,k,ipowno3) = powtra(i,j,k,ipowno3) + posol*umfa*rnit
              if (use_cisonew) then
                sedlay(i,j,k,issso13) = sedlay(i,j,k,issso13) - poso13
                sedlay(i,j,k,issso14) = sedlay(i,j,k,issso14) - poso14
              endif
              if (use_extNcycle) then
                extNsed_diagnostics(i,j,k,ised_remin_sulf) = posol*umfa ! Output
              else
                sed_rem_sulf(i,j,k) = posol * umfa
              endif
            endif
          endif
        enddo
      enddo   ! end sulphate reduction


      ! Calculate CaCO3-CO3 cycle and simultaneous CO3-undersaturation diffusion
      !*************************************************************************

      ! Compute new powcar, carbonate ion concentration in the sediment
      ! from changed alkalinity (nitrate production during remineralisation)
      ! and DIC gain.

      do k = 1, ks
        do i = 1, kpie
          if(omask(i,j) > 0.5_rp) then
            rrho= prho(i,j,kbo(i,j))
            if (use_extNcycle) then
              alk = (powtra(i,j,k,ipowaal) - (sulf(i,k)+aerob(i,k))*(rnit+1._rp) + ex_dalk(i,k))  / rrho
              c   = (powtra(i,j,k,ipowaic) + (aerob(i,k)+sulf(i,k))*rcar + ex_ddic(i,k)) / rrho
            else
              alk = (powtra(i,j,k,ipowaal) - (sulf(i,k)+aerob(i,k))*(rnit+1._rp) + anaerob(i,k)*(rdnit1-1._rp))  / rrho
              c   = (powtra(i,j,k,ipowaic) + (anaerob(i,k)+aerob(i,k)+sulf(i,k))*rcar) / rrho
            endif
            sit =  powtra(i,j,k,ipowasi) / rrho
            pt  =  powtra(i,j,k,ipowaph) / rrho
            ah1 = sedhpl(i,j,k)
            K1  = keqb( 1,i,j)
            K2  = keqb( 2,i,j)
            Kb  = keqb( 3,i,j)
            Kw  = keqb( 4,i,j)
            Ks1 = keqb( 5,i,j)
            Kf  = keqb( 6,i,j)
            Ksi = keqb( 7,i,j)
            K1p = keqb( 8,i,j)
            K2p = keqb( 9,i,j)
            K3p = keqb(10,i,j)

            call carchm_solve(psao(i,j,kbo(i,j)),c,alk,sit,pt,K1,K2,Kb,Kw,Ks1,Kf,Ksi,K1p,K2p,K3p,ah1,ac)

            cu = ( 2._rp * c - ac ) / ( 2._rp + K1 / ah1 )
            cb = K1 * cu / ah1
            cc = K2 * cb / ah1
            sedhpl(i,j,k) = max( 1.e-20_rp, ah1 )
            powcar(i,k)   = cc * rrho
          endif
        enddo
      enddo

      ! Dissolution rate constant of CaCO3 (disso) [1/(kmol CO3--/m3)*1/sec]*dtbgc
      dissot = disso_caco3

      ! Evaluate boundary conditions for sediment-water column exchange.
      ! Current undersaturation of bottom water: sedb(i,0) and
      ! Approximation for new solid sediment, as from sedimentation flux: solrat(i,1)

      ! CO3 saturation concentration is aksp/calcon as in CARCHM
      ! (calcon defined in MO_CHEMCON with 1.028e-2; 1/calcon =~ 97.)

      do i = 1, kpie
        if(omask(i,j) > 0.5_rp) then
          satlev = keqb(11,i,j) / calcon + 2.e-5_rp
          undsa = max( satlev-powcar(i,1), 0._rp )
          sedb1(i,0) = bolay(i,j) * (satlev-co3(i,j,kbo(i,j)))
          solrat(i,1) = (sedlay(i,j,1,isssc12)                                                     &
               &   + prcaca(i,j) / (porsol(i,j,1)*seddw(1)))                                       &
               &   * dissot / (1._rp+dissot*undsa) * porsol(i,j,1) / porwat(i,j,1)
        endif
      enddo

      ! Evaluate sediment undersaturation and degradation.
      ! Current undersaturation in pore water: sedb(i,k) and
      ! Approximation for new solid sediment, as from degradation: solrat(i,k)

      do k = 1, ks
        do i = 1, kpie
          if(omask(i,j) > 0.5_rp) then
            undsa = max( keqb(11,i,j) / calcon - powcar(i,k), 0._rp )
            sedb1(i,k) = seddw(k) * porwat(i,j,k) * undsa
            if (k > 1) then
              solrat(i,k) = sedlay(i,j,k,isssc12) * dissot/(1._rp+dissot*undsa) * porsol(i,j,k)/porwat(i,j,k)
            end if
            if (undsa <= 0._rp) then
              solrat(i,k) = 0._rp
            end if
          endif
        enddo
      enddo

      ! Solve for new undersaturation sediso, from current undersaturation sedb1,
      ! and first guess of new solid sediment solrat.

      call powadi(j,kpie,kpje,solrat,sedb1,sediso,omask)

      ! There is no exchange between water and sediment with respect to co3 so far.
      ! Add sedimentation to first layer.
      do i = 1, kpie
        if(omask(i,j) > 0.5_rp) then
          sedlay(i,j,1,isssc12) =                                                                  &
                 &   sedlay(i,j,1,isssc12) + prcaca(i,j) / (porsol(i,j,1)*seddw(1))
          if (use_cisonew) then
            sedlay(i,j,1,isssc13) =                                                                &
                 &   sedlay(i,j,1,isssc13) + prca13(i,j) / (porsol(i,j,1)*seddw(1))
            sedlay(i,j,1,isssc14) =                                                                &
                 &   sedlay(i,j,1,isssc14) + prca14(i,j) / (porsol(i,j,1)*seddw(1))
          endif
        endif
      enddo

      ! Calculate updated degradation rate from updated undersaturation.
      ! Calculate new solid sediment.
      ! No update of powcar pore water concentration from new undersaturation so far.
      ! Instead, only update DIC, and, of course, alkalinity.
      ! This also includes gains from aerobic and anaerobic decomposition.

      do k = 1, ks
        do i = 1, kpie
          if(omask(i,j) > 0.5_rp) then
            umfa = porsol(i,j,k) / porwat(i,j,k)
            solrat(i,k) = sedlay(i,j,k,isssc12) * dissot / (1._rp + dissot * sediso(i,k))
            posol = sediso(i,k) * solrat(i,k)
            if (use_cisonew) then
              ratc13 = sedlay(i,j,k,isssc13) / (sedlay(i,j,k,isssc12) + safediv)
              ratc14 = sedlay(i,j,k,isssc14) / (sedlay(i,j,k,isssc12) + safediv)
              poso13 = posol * ratc13
              poso14 = posol * ratc14
            endif
            sedlay(i,j,k,isssc12) = sedlay(i,j,k,isssc12) - posol
            if (use_extNcycle) then
              powtra(i,j,k,ipowaic) = powtra(i,j,k,ipowaic)                                        &
                  &   + posol * umfa + (aerob(i,k) + sulf(i,k)) * rcar + ex_ddic(i,k)
              powtra(i,j,k,ipowaal) = powtra(i,j,k,ipowaal)                                        &
                  &   + 2._rp * posol * umfa - (rnit+1._rp)*(aerob(i,k) + sulf(i,k))  + ex_dalk(i,k)
            else
              powtra(i,j,k,ipowaic) = powtra(i,j,k,ipowaic)                                        &
                  &   + posol * umfa + (aerob(i,k) + anaerob(i,k) + sulf(i,k)) * rcar
              powtra(i,j,k,ipowaal) = powtra(i,j,k,ipowaal)                                        &
                  &   + 2._rp * posol * umfa - (rnit+1._rp)*(aerob(i,k) + sulf(i,k))               &
                  &   + (rdnit1-1._rp)*anaerob(i,k)
            endif
            if (use_cisonew) then
              sedlay(i,j,k,isssc13) = sedlay(i,j,k,isssc13) - poso13
              sedlay(i,j,k,isssc14) = sedlay(i,j,k,isssc14) - poso14
              powtra(i,j,k,ipowc13) = powtra(i,j,k,ipowc13) + poso13 * umfa                        &
                 &   + (aerob13(i,k) + anaerob13(i,k) + sulf13(i,k)) * rcar
              powtra(i,j,k,ipowc14) = powtra(i,j,k,ipowc14) + poso14 * umfa                        &
                 &   + (aerob14(i,k) + anaerob14(i,k) + sulf14(i,k)) * rcar
            endif
          endif
        enddo
      enddo

    enddo j_loop

    !$OMP END PARALLEL DO

    call dipowa(kpie,kpje,kpke,omask,lspin)

    !ik add clay sedimentation onto sediment
    !ik this is currently assumed to depend on total and corg sedimentation:
    !ik f(POC) [kg C] / f(total) [kg] = 0.05
    !ik thus it is
    !$OMP PARALLEL DO PRIVATE(i)
    do j = 1, kpje
      do i = 1, kpie
        sedlay(i,j,1,issster) = sedlay(i,j,1,issster) + produs(i,j) / (porsol(i,j,1) * seddw(1))
      enddo
    enddo
    !$OMP END PARALLEL DO

    if(.not. lspin) then
      !$OMP PARALLEL DO PRIVATE(i)
      do j = 1, kpje
        do i = 1, kpie
          silpro(i,j) = 0._rp
          prorca(i,j) = 0._rp
          prcaca(i,j) = 0._rp
          if (use_cisonew) then
            pror13(i,j) = 0._rp
            pror14(i,j) = 0._rp
            prca13(i,j) = 0._rp
            prca14(i,j) = 0._rp
          endif
          produs(i,j) = 0._rp
        enddo
      enddo
      !$OMP END PARALLEL DO
    endif

  end subroutine powach

end module mo_powach
