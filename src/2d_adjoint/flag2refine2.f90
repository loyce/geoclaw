! ::::::::::::::::::::: flag2refine ::::::::::::::::::::::::::::::::::
!
! Modified flag2refine file to use adjoint-flagging.
!
! Default version computes spatial difference dq in each direction and
! for each component of q and flags any point where this is greater than
! the tolerance tolsp.  This is consistent with what the routine errsp did in
! earlier versions of amrclaw (4.2 and before).
!
! This routine can be copied to an application directory and modified to
! implement some other desired refinement criterion.
!
! Points may also be flagged for refining based on a Richardson estimate
! of the error, obtained by comparing solutions on the current grid and a
! coarsened grid.  Points are flagged if the estimated error is larger than
! the parameter tol in amr2ez.data, provided flag_richardson is .true.,
! otherwise the coarsening and Richardson estimation is not performed!  
! Points are flagged via Richardson in a separate routine.
!
! Once points are flagged via this routine and/or Richardson, the subroutine
! flagregions is applied to check each point against the min_level and
! max_level of refinement specified in any "region" set by the user.
! So flags set here might be over-ruled by region constraints.
!
!    q   = grid values including ghost cells (bndry vals at specified
!          time have already been set, so can use ghost cell values too)
!
!  aux   = aux array on this grid patch
!
! amrflags  = array to be flagged with either the value
!             DONTFLAG (no refinement needed)  or
!             DOFLAG   (refinement desired)    
!
! tolsp = tolerance specified by user in input file amr2ez.data, used in default
!         version of this routine as a tolerance for spatial differences.
!
! ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

subroutine flag2refine2(mx,my,mbc,mbuff,meqn,maux,xlower,ylower,dx,dy,t,level, &
                            tolsp,q,aux,amrflags,DONTFLAG,DOFLAG)

    use innerprod_module, only: calculate_innerproduct
    use adjoint_module, only: totnum_adjoints, innerprod_index
    use adjoint_module, only: adjoints, trange_start, trange_final

    use amr_module, only: mxnest, t0
    use geoclaw_module, only:dry_tolerance, sea_level

    use topo_module, only: tlowtopo,thitopo,xlowtopo,xhitopo,ylowtopo,yhitopo
    use topo_module, only: minleveltopo,mtopofiles

    use topo_module, only: tfdtopo,xlowdtopo,xhidtopo,ylowdtopo,yhidtopo
    use topo_module, only: minleveldtopo,num_dtopo

    use qinit_module, only: x_low_qinit,x_hi_qinit,y_low_qinit,y_hi_qinit
    use qinit_module, only: min_level_qinit,qinit_type

    use regions_module, only: num_regions, regions
    use refinement_module

    implicit none

    ! Subroutine arguments
    integer, intent(in) :: mx,my,mbc,meqn,maux,level,mbuff
    real(kind=8), intent(in) :: xlower,ylower,dx,dy,t,tolsp
    
    real(kind=8), intent(in) :: q(meqn,1-mbc:mx+mbc,1-mbc:my+mbc)
    real(kind=8), intent(inout) :: aux(maux,1-mbc:mx+mbc,1-mbc:my+mbc)
    
    ! Flagging
    real(kind=8),intent(inout) :: amrflags(1-mbuff:mx+mbuff,1-mbuff:my+mbuff)
    real(kind=8), intent(in) :: DONTFLAG
    real(kind=8), intent(in) :: DOFLAG
    
    logical :: allowflag
    external allowflag

    ! Locals
    integer :: i,j,m,r
    real(kind=8) :: max_innerprod
    real(kind=8) :: x_c,y_c,x_low,y_low,x_hi,y_hi
    real(kind=8) :: dqi(meqn), dqj(meqn), dq(meqn),eta
    logical :: checkregions
    logical :: mask_selecta(totnum_adjoints), adjoints_found
    real(kind=8) :: aux_temp(mx,my)

    ! Initialize flags
    amrflags = DONTFLAG
    checkregions = .TRUE.
    aux(innerprod_index,:,:) = 0.0
    mask_selecta = .false.
    adjoints_found = .false.

    y_loop: do j = 1,my
      y_c = ylower + (j - 0.5d0) * dy
      y_low = ylower + (j - 1) * dy
      y_hi = ylower + j * dy

      x_loop: do i = 1,mx
        x_c = xlower + (i - 0.5d0) * dx
        x_low = xlower + (i - 1) * dx
        x_hi = xlower + i * dx

        ! Check to see if refinement is forced in any topography file region:
        do m=1,mtopofiles
          if (level < minleveltopo(m) .and. t >= tlowtopo(m) .and. t <= thitopo(m)) then
            if (  x_hi > xlowtopo(m) .and. x_low < xhitopo(m) .and. &
              y_hi > ylowtopo(m) .and. y_low < yhitopo(m) ) then

              amrflags(i,j) = DOFLAG
              aux(innerprod_index,i,j) = 1.d10 ! indicate amr forced
              cycle x_loop
            endif
          endif
        enddo

        ! Check to see if refinement is forced in any other region:
        do m=1,num_regions
          if (level < regions(m)%min_level .and. &
            t >= regions(m)%t_low .and. t <= regions(m)%t_hi) then
            if (x_hi > regions(m)%x_low .and. x_low < regions(m)%x_hi .and. &
              y_hi > regions(m)%y_low .and. y_low < regions(m)%y_hi ) then

              amrflags(i,j) = DOFLAG
              aux(innerprod_index,i,j) = 1.d10 ! indicate amr forced
              cycle x_loop
            endif
          endif
        enddo

        ! Check if we're in the dtopo region and need to refine:
        ! force refinement to level minleveldtopo
        do m = 1,num_dtopo
          if (level < minleveldtopo(m).and. &
            t <= tfdtopo(m) .and. & !t.ge.t0dtopo(m).and.
            x_hi > xlowdtopo(m) .and. x_low < xhidtopo(m).and. &
            y_hi > ylowdtopo(m) .and. y_low < yhidtopo(m)) then

            amrflags(i,j) = DOFLAG
            aux(innerprod_index,i,j) = 1.d10 ! indicate amr forced
            cycle x_loop
          endif
        enddo

        ! Check if we're in the region where initial perturbation is
        ! specified and need to force refinement:
        ! This assumes that t0 = 0.d0, should really be t0 but we do
        ! not have access to that parameter in this routine
        if (qinit_type > 0 .and. t == t0) then
          if (level < min_level_qinit .and. &
            x_hi > x_low_qinit .and. x_low < x_hi_qinit .and. &
            y_hi > y_low_qinit .and. y_low < y_hi_qinit) then

            amrflags(i,j) = DOFLAG
            aux(innerprod_index,i,j) = 1.d10 ! indicate amr forced
            cycle x_loop
          endif
        endif
      enddo x_loop
    enddo y_loop
    ! Finished checking if refinement is forced

    ! -----------------------------------------------------------------
    ! Check if refinment is allowed and if so,
    ! check if there is a reason to flag this point:

    ! Loop over adjoint snapshots
    do r=1,totnum_adjoints
        if ((t+adjoints(r)%time) >= trange_start .and. &
               (t+adjoints(r)%time) <= trange_final) then
            mask_selecta(r) = .true.
            adjoints_found = .true.
        endif
    enddo

    if(.not. adjoints_found) then
        write(*,*) "Note: no adjoint snapshots found in time range."
        write(*,*) "Consider increasing time rage of interest, or adding more snapshots."
    endif


    do r=1,totnum_adjoints-1
        if((.not. mask_selecta(r)) .and. &
                (mask_selecta(r+1))) then
            mask_selecta(r) = .true.
            exit
        endif
    enddo

    do r=totnum_adjoints,2,-1
        if((.not. mask_selecta(r)) .and. &
               (mask_selecta(r-1))) then
            mask_selecta(r) = .true.
            exit
        endif
    enddo

    aloop: do r=1,totnum_adjoints

        ! Consider only snapshots that are within the desired time range
        if (mask_selecta(r)) then
            ! Calculate inner product with current snapshot
            aux_temp(:,:) = calculate_innerproduct &
                  (t,q,r,mx,my,xlower,ylower,dx,dy,meqn,mbc,aux(1,:,:))

            ! Save max inner product
            do i=1,mx
                do j = 1,my
                    aux(innerprod_index,i,j) = &
                           max(aux(innerprod_index,i,j), &
                           aux_temp(i,j))
                enddo
            enddo
        endif

    enddo aloop

    ! Flag locations that need refining
    y_loop2: do j = 1,my
        y_c = ylower + (j - 0.5d0) * dy
        x_loop2: do i = 1,mx
            x_c = xlower + (i - 0.5d0) * dx

            if (allowflag(x_c,y_c,t,level) .and. aux(innerprod_index,i,j) > tolsp) then
                amrflags(i,j) = DOFLAG
                cycle x_loop2
            endif
        enddo x_loop2
    enddo y_loop2

end subroutine flag2refine2
