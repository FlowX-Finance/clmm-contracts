module flowx_clmm::tick {
    use sui::table::{Self, Table};

    use flowx_clmm::i32::{Self, I32};
    use flowx_clmm::i128::{Self, I128};
    use flowx_clmm::tick_math;
    use flowx_clmm::constants;
    use flowx_clmm::liquidity_math;

    friend flowx_clmm::pool;

    const E_LIQUIDITY_OVERFLOW: u64 = 0;
    const E_TICKS_MISORDERED: u64 = 1;
    const E_TICK_LOWER_OUT_OF_BOUNDS: u64 = 2;
    const E_TICK_UPPER_OUT_OF_BOUNDS: u64 = 3;

    struct TickInfo has copy, drop, store {
        liquidity_gross: u128,
        liquidity_net: I128,
        fee_growth_outside_x: u128,
        fee_growth_outside_y: u128
    }

    public fun check_ticks(tick_lower_index: I32, tick_upper_index: I32)  {
        if (i32::gte(tick_lower_index, tick_upper_index)) {
            abort E_TICKS_MISORDERED
        };
        if (i32::lt(tick_lower_index, tick_math::min_tick())) {
            abort E_TICK_LOWER_OUT_OF_BOUNDS
        };
        if (i32::gt(tick_upper_index, tick_math::max_tick())) {
            abort E_TICK_UPPER_OUT_OF_BOUNDS
        };
    }

    public fun is_initialized(
        self: &Table<I32, TickInfo>,
        tick_index: I32
    ): bool {
        table::contains(self, tick_index)
    }

    public fun get_fee_growth_outside(
        self: &Table<I32, TickInfo>,
        tick_index: I32
    ): (u128, u128) {
        if (!is_initialized(self, tick_index)) {
            (0, 0)
        } else {
            let tick_info = table::borrow(self, tick_index);
            (tick_info.fee_growth_outside_x, tick_info.fee_growth_outside_y)
        }
    }

    public fun get_liquidity_gross(
        self: &Table<I32, TickInfo>,
        tick_index: I32
    ): u128 {
        if (!is_initialized(self, tick_index)) {
            0
        } else {
            let tick_info = table::borrow(self, tick_index);
            tick_info.liquidity_gross
        }
    }

    public fun get_liquidity_net(
        self: &Table<I32, TickInfo>,
        tick_index: I32
    ): I128 {
        if (!is_initialized(self, tick_index)) {
            i128::zero()
        } else {
            let tick_info = table::borrow(self, tick_index);
            tick_info.liquidity_net
        }
    }

    fun try_borrow_mut_tick(
        self: &mut Table<I32, TickInfo>,
        tick_index: I32
    ): &mut TickInfo {
        if (!table::contains(self, tick_index)) {
            let tick_info = TickInfo {
                liquidity_gross: 0,
                liquidity_net: i128::zero(),
                fee_growth_outside_x: 0,
                fee_growth_outside_y: 0
            };
            table::add(self, tick_index, tick_info);
        };

        table::borrow_mut(self, tick_index)
    }

    public fun tick_spacing_to_max_liquidity_per_tick(tick_spacing: u32): u128 {
        let tick_spacing_i32 = i32::from(tick_spacing);
        let min_tick = i32::mul(i32::div(tick_math::min_tick(), tick_spacing_i32), tick_spacing_i32);
        let max_tick = i32::mul(i32::div(tick_math::max_tick(), tick_spacing_i32), tick_spacing_i32);
        let num_ticks = i32::as_u32(i32::div(i32::sub(max_tick, min_tick), tick_spacing_i32)) + 1;
        (constants::get_max_u128() / (num_ticks as u128))
    }

    public fun get_fee_growth_inside(
        self: &Table<I32, TickInfo>,
        tick_lower_index: I32,
        tick_upper_index: I32,
        tick_current_index: I32,
        fee_growth_global_x: u128,
        fee_growth_global_y: u128
    ): (u128, u128) {
        let (lower_fee_growth_outside_x, lower_fee_growth_outside_y) = get_fee_growth_outside(self, tick_lower_index);
        let (upper_fee_growth_outside_x, upper_fee_growth_outside_y) = get_fee_growth_outside(self, tick_upper_index);

        let (fee_growth_below_x, fee_growth_below_y) = if (i32::gte(tick_current_index, tick_lower_index)) {
            (lower_fee_growth_outside_x, lower_fee_growth_outside_y)
        } else {
            (
                fee_growth_global_x - lower_fee_growth_outside_x,
                fee_growth_global_y - lower_fee_growth_outside_y
            )
        };

        let (fee_growth_above_x, fee_growth_above_y) = if (i32::lt(tick_current_index, tick_upper_index)) {
            (upper_fee_growth_outside_x, upper_fee_growth_outside_y)
        } else {
            (
                fee_growth_global_x - upper_fee_growth_outside_x,
                fee_growth_global_y - upper_fee_growth_outside_y
            )
        };

        (
            fee_growth_global_x - fee_growth_below_x - fee_growth_above_x,
            fee_growth_global_y - fee_growth_below_y - fee_growth_above_y
        )
    }

    public(friend) fun update(
        self: &mut Table<I32, TickInfo>,
        tick_index: I32,
        tick_current_index: I32,
        liquidity_delta: I128,
        fee_growth_global_x: u128,
        fee_growth_global_y: u128,
        upper: bool,
        max_liquidity: u128
    ): bool {
        let tick_info = try_borrow_mut_tick(self, tick_index);
        let liquidity_gross_before = tick_info.liquidity_gross;
        let liquidity_gross_after = liquidity_math::add_delta(liquidity_gross_before, liquidity_delta);

        assert!(liquidity_gross_after <= max_liquidity, E_LIQUIDITY_OVERFLOW);

        let flipped = (liquidity_gross_after == 0) != (liquidity_gross_before == 0);

        if (liquidity_gross_before == 0) {
            if (i32::lte(tick_index, tick_current_index)) {
                tick_info.fee_growth_outside_x = fee_growth_global_x;
                tick_info.fee_growth_outside_y = fee_growth_global_y;
            };
        };

        tick_info.liquidity_gross = liquidity_gross_after;

        tick_info.liquidity_net = if (upper) {
            i128::sub(tick_info.liquidity_net, liquidity_delta)
        } else {
            i128::add(tick_info.liquidity_net, liquidity_delta)
        };
        
        flipped
    }

    public(friend) fun clear(self: &mut Table<I32, TickInfo>, tick: I32) {
        table::remove(self, tick);
    }

    public(friend) fun cross(
        self: &mut Table<I32, TickInfo>,
        tick_index: I32,
        fee_growth_global_x: u128,
        fee_growth_global_y: u128
    ): I128 {
        let tick_info = try_borrow_mut_tick(self, tick_index);
        tick_info.fee_growth_outside_x = fee_growth_global_x - tick_info.fee_growth_outside_x;
        tick_info.fee_growth_outside_y = fee_growth_global_y - tick_info.fee_growth_outside_y;
        tick_info.liquidity_net
    }

    #[test]
    public fun test_tick_spacing_to_max_liquidity_per_tick() {
        let max_liquidity_per_tick = tick_spacing_to_max_liquidity_per_tick(10);
        assert!(max_liquidity_per_tick == 3835161415588698631345301964810804, 0);

        let max_liquidity_per_tick = tick_spacing_to_max_liquidity_per_tick(60);
        assert!(max_liquidity_per_tick == 23012265295255187899058267899625901, 0);

        let max_liquidity_per_tick = tick_spacing_to_max_liquidity_per_tick(200);
        assert!(max_liquidity_per_tick == 76691991643213536953656661580294841, 0);

        let max_liquidity_per_tick = tick_spacing_to_max_liquidity_per_tick(443636);
        assert!(max_liquidity_per_tick == flowx_clmm::constants::get_max_u128() / 3, 0);

        let max_liquidity_per_tick = tick_spacing_to_max_liquidity_per_tick(2302);
        assert!(max_liquidity_per_tick == 883850303690749255749024954368229120, 0);
    }
    
    #[test]
    public fun test_get_fee_growth_inside() {
        use sui::table;
        use sui::tx_context;
        use flowx_clmm::i32::{Self, I32};
        use flowx_clmm::i128;

        let ticks = table::new<I32, TickInfo>(&mut tx_context::dummy());

        //returns all for two uninitialized ticks if tick is inside
        let (fee_growth_inside_x, fee_growth_inside_y) 
            = get_fee_growth_inside(&ticks, i32::neg_from(2), i32::from(2), i32::zero(), 15, 15);
        assert!(fee_growth_inside_x == 15 && fee_growth_inside_y == 15, 0);

        //returns 0 for two uninitialized ticks if tick is above
        let (fee_growth_inside_x, fee_growth_inside_y) 
            = get_fee_growth_inside(&ticks, i32::neg_from(2), i32::from(2), i32::from(4), 15, 15);
        assert!(fee_growth_inside_x == 0 && fee_growth_inside_y == 0, 0);

        //returns 0 for two uninitialized ticks if tick is below
        let (fee_growth_inside_x, fee_growth_inside_y) 
            = get_fee_growth_inside(&ticks, i32::neg_from(2), i32::from(2), i32::neg_from(4), 15, 15);
        assert!(fee_growth_inside_x == 0 && fee_growth_inside_y == 0, 0);

        //subtracts upper tick if below
        table::add(&mut ticks, i32::from(2), TickInfo {
            liquidity_gross: 0,
            liquidity_net: i128::zero(),
            fee_growth_outside_x: 2,
            fee_growth_outside_y: 3
        });
        let (fee_growth_inside_x, fee_growth_inside_y) 
            = get_fee_growth_inside(&ticks, i32::neg_from(2), i32::from(2), i32::zero(), 15, 15);
        assert!(fee_growth_inside_x == 13 && fee_growth_inside_y == 12, 0);

        //subtracts lower tick if above
        table::add(&mut ticks, i32::neg_from(2), TickInfo {
            liquidity_gross: 0,
            liquidity_net: i128::zero(),
            fee_growth_outside_x: 2,
            fee_growth_outside_y: 3
        });
        let (fee_growth_inside_x, fee_growth_inside_y) 
            = get_fee_growth_inside(&ticks, i32::neg_from(2), i32::from(2), i32::zero(), 15, 15);
        assert!(fee_growth_inside_x == 11 && fee_growth_inside_y == 9, 0);

        table::drop(ticks);
    }

    #[test]
    public fun test_update() {
        use sui::table;
        use sui::tx_context;
        use flowx_clmm::i32::{Self, I32};
        use flowx_clmm::i128;

        let ticks = table::new<I32, TickInfo>(&mut tx_context::dummy());
        
        //flips from zero to nonzero
        assert!(update(&mut ticks, i32::from(0), i32::from(0), i128::from(1), 0, 0, false, 3) == true, 0);

        //does not flip from nonzero to greater nonzero
        assert!(update(&mut ticks, i32::from(0), i32::from(0), i128::from(1), 0, 0, false, 3) == false, 0);

        //flips from nonzero to zero
        assert!(update(&mut ticks, i32::from(0), i32::from(0), i128::neg_from(2), 0, 0, false, 3) == true, 0);

        //does not flip from nonzero to lesser nonzero
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(2), 0, 0, false, 3);
        assert!(update(&mut ticks, i32::from(0), i32::from(0), i128::neg_from(1), 0, 0, false, 3) == false, 0);

        //nets the liquidity based on upper flag
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(2), 0, 0, false, 10);
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(1), 0, 0, true, 10);
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(3), 0, 0, true, 10);
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(1), 0, 0, false, 10);

        let (liquidity_gross, liquidity_net) = (get_liquidity_gross(&ticks, i32::from(0)), get_liquidity_net(&ticks, i32::from(0)));
        assert!(liquidity_gross == (1 + 2 + 1 + 3 + 1), 0);
        assert!(i128::eq(liquidity_net, i128::zero()), 0);

        //assumes all growth happens below ticks lte current tick
        update(&mut ticks, i32::from(1), i32::from(1), i128::from(1), 1, 2, false, 10);
        assert!(is_initialized(&ticks, i32::from(1)), 0);
        let (liquidity_gross, liquidity_net) = (get_liquidity_gross(&ticks, i32::from(0)), get_liquidity_net(&ticks, i32::from(0)));
        let (fee_growth_outside_x, fee_growth_outside_y) = get_fee_growth_outside(&ticks, i32::from(1));
        assert!(liquidity_gross == (1 + 2 + 1 + 3 + 1), 0);
        assert!(i128::eq(liquidity_net, i128::zero()), 0);
        assert!(fee_growth_outside_x == 1 && fee_growth_outside_y == 2, 0);

        //does not set any growth fields if tick is already initialized
        update(&mut ticks, i32::from(1), i32::from(1), i128::from(1), 6, 7, false, 10);
        let (fee_growth_outside_x, fee_growth_outside_y) = get_fee_growth_outside(&ticks, i32::from(1));
        assert!(fee_growth_outside_x == 1 && fee_growth_outside_y == 2, 0);

        //does not set any growth fields for ticks gt current tick
        update(&mut ticks, i32::from(2), i32::from(1), i128::from(1), 1, 2, false, 10);
        let (liquidity_gross, liquidity_net) = (get_liquidity_gross(&ticks, i32::from(2)), get_liquidity_net(&ticks, i32::from(2)));
        let (fee_growth_outside_x, fee_growth_outside_y) = get_fee_growth_outside(&ticks, i32::from(2));
        assert!(liquidity_gross == 1, 0);
        assert!(i128::eq(liquidity_net, i128::from(1)), 0);
        assert!(fee_growth_outside_x == 0 && fee_growth_outside_y == 0, 0);

        table::drop(ticks);
    }

    #[test]
    #[expected_failure(abort_code = E_LIQUIDITY_OVERFLOW)]
    public fun test_update_failed_if_liquidity_gross_is_exceed_max() {
        use sui::table;
        use sui::tx_context;
        use flowx_clmm::i32::{Self, I32};
        use flowx_clmm::i128;

        let ticks = table::new<I32, TickInfo>(&mut tx_context::dummy());

        update(&mut ticks, i32::from(0), i32::from(0), i128::from(2), 0, 0, false, 3);
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(1), 0, 0, true, 3);
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(3), 0, 0, true, 3);
        
        table::drop(ticks);
    }

    #[test]
    public fun test_cross() {
        use sui::table;
        use sui::tx_context;
        use flowx_clmm::i32::{Self, I32};
        use flowx_clmm::i128;

        let ticks = table::new<I32, TickInfo>(&mut tx_context::dummy());

        //flips the growth variables
        table::add(&mut ticks, i32::from(2), TickInfo {
            liquidity_gross: 1,
            liquidity_net: i128::from(2),
            fee_growth_outside_x: 3,
            fee_growth_outside_y: 4
        });
        assert!(i128::eq(cross(&mut ticks, i32::from(2), 5, 7), i128::from(2)), 0);
        let (fee_growth_outside_x, fee_growth_outside_y) = get_fee_growth_outside(&ticks, i32::from(2));
        assert!(fee_growth_outside_x == 2 && fee_growth_outside_y == 3, 0);

        //two flips are no op
        table::add(&mut ticks, i32::from(3), TickInfo {
            liquidity_gross: 3,
            liquidity_net: i128::from(4),
            fee_growth_outside_x: 1,
            fee_growth_outside_y: 2
        });
        assert!(i128::eq(cross(&mut ticks, i32::from(3), 5, 7), i128::from(4)), 0);
        assert!(i128::eq(cross(&mut ticks, i32::from(3), 5, 7), i128::from(4)), 0);
        let (fee_growth_outside_x, fee_growth_outside_y) = get_fee_growth_outside(&ticks, i32::from(3));
        assert!(fee_growth_outside_x == 1 && fee_growth_outside_y == 2, 0);

        table::drop(ticks);
    }
}