module flowx_clmm::tick {
    use std::vector;
    use sui::table::{Self, Table};

    use flowx_clmm::i32::{Self, I32};
    use flowx_clmm::i64::{Self, I64};
    use flowx_clmm::i128::{Self, I128};
    use flowx_clmm::tick_math;
    use flowx_clmm::constants;
    use flowx_clmm::liquidity_math;
    use flowx_clmm::full_math_u128;

    friend flowx_clmm::pool;

    const E_LIQUIDITY_OVERFLOW: u64 = 0;
    const E_TICKS_MISORDERED: u64 = 1;
    const E_TICK_LOWER_OUT_OF_BOUNDS: u64 = 2;
    const E_TICK_UPPER_OUT_OF_BOUNDS: u64 = 3;
    const E_TICK_MISALIGNED: u64 = 4;

    struct TickInfo has copy, drop, store {
        liquidity_gross: u128,
        liquidity_net: I128,
        fee_growth_outside_x: u128,
        fee_growth_outside_y: u128,
        reward_growths_outside: vector<u128>,
        tick_cumulative_out_side: I64,
        seconds_per_liquidity_out_side: u256,
        seconds_out_side: u64
    }

    public fun check_ticks(tick_lower_index: I32, tick_upper_index: I32, tick_spacing: u32) {
        if (i32::abs_u32(tick_lower_index) % tick_spacing != 0 || i32::abs_u32(tick_upper_index) % tick_spacing != 0) {
            abort E_TICK_MISALIGNED
        };
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

    public fun get_fee_and_reward_growths_outside(
        self: &Table<I32, TickInfo>,
        tick_index: I32
    ): (u128, u128, vector<u128>) {
        if (!is_initialized(self, tick_index)) {
            (0, 0, vector::empty())
        } else {
            let tick_info = table::borrow(self, tick_index);
            (tick_info.fee_growth_outside_x, tick_info.fee_growth_outside_y, tick_info.reward_growths_outside)
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

    public fun get_tick_cumulative_out_side(
        self: &Table<I32, TickInfo>,
        tick_index: I32
    ): I64 {
        if (!is_initialized(self, tick_index)) {
            i64::zero()
        } else {
            let tick_info = table::borrow(self, tick_index);
            tick_info.tick_cumulative_out_side
        }
    }

    public fun get_seconds_per_liquidity_out_side(
        self: &Table<I32, TickInfo>,
        tick_index: I32
    ): u256 {
        if (!is_initialized(self, tick_index)) {
            0
        } else {
            let tick_info = table::borrow(self, tick_index);
            tick_info.seconds_per_liquidity_out_side
        }
    }

    public fun get_seconds_out_side(
        self: &Table<I32, TickInfo>,
        tick_index: I32
    ): u64 {
        if (!is_initialized(self, tick_index)) {
            0
        } else {
            let tick_info = table::borrow(self, tick_index);
            tick_info.seconds_out_side
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
                fee_growth_outside_y: 0,
                reward_growths_outside: vector::empty(),
                seconds_per_liquidity_out_side: 0,
                tick_cumulative_out_side: i64::zero(),
                seconds_out_side: 0
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

    /// Returns the fee and reward growths inside the specified tick range.
    /// @dev This function calculates the fee and reward growths inside the tick range defined by `tick_lower_index` and `tick_upper_index`.
    /// @param self The mapping containing all tick information for initialized ticks.
    /// @param tick_lower_index The lower tick boundary of the position.
    /// @param tick_upper_index The upper tick boundary of the position.
    /// @param tick_current_index The current tick index.
    /// @param fee_growth_global_x The all-time global fee growth, per unit of liquidity, in token X.
    /// @param fee_growth_global_y The all-time global fee growth, per unit of liquidity, in token Y.
    /// @param reward_growths_global The all-time global reward growths, per unit of liquidity, for each reward type.
    /// @return The all-time fee growth in tokenX, per unit of liquidity, inside the position's tick boundaries.
    /// @return The all-time fee growth in tokenY, per unit of liquidity, inside the position's tick boundaries.
    /// @return The all-time reward growths, per unit of liquidity, inside the position's tick boundaries.
    public fun get_fee_and_reward_growths_inside(
        self: &Table<I32, TickInfo>,
        tick_lower_index: I32,
        tick_upper_index: I32,
        tick_current_index: I32,
        fee_growth_global_x: u128,
        fee_growth_global_y: u128,
        reward_growths_global: vector<u128>
    ): (u128, u128, vector<u128>) {
        let (lower_fee_growth_outside_x, lower_fee_growth_outside_y, lower_reward_growths_outside) = get_fee_and_reward_growths_outside(self, tick_lower_index);
        let (upper_fee_growth_outside_x, upper_fee_growth_outside_y, upper_reward_growths_outside) = get_fee_and_reward_growths_outside(self, tick_upper_index);

        
        let (fee_growth_below_x, fee_growth_below_y, reward_growths_below) = if (i32::gte(tick_current_index, tick_lower_index)) {
            (lower_fee_growth_outside_x, lower_fee_growth_outside_y, lower_reward_growths_outside)
        } else {
            (
                full_math_u128::wrapping_sub(fee_growth_global_x, lower_fee_growth_outside_x),
                full_math_u128::wrapping_sub(fee_growth_global_y, lower_fee_growth_outside_y),
                compute_reward_growths(reward_growths_global, lower_reward_growths_outside)
            )
        };

        let (fee_growth_above_x, fee_growth_above_y, reward_growths_above) = if (i32::lt(tick_current_index, tick_upper_index)) {
            (upper_fee_growth_outside_x, upper_fee_growth_outside_y, upper_reward_growths_outside)
        } else {
            (
                full_math_u128::wrapping_sub(fee_growth_global_x, upper_fee_growth_outside_x),
                full_math_u128::wrapping_sub(fee_growth_global_y, upper_fee_growth_outside_y),
                compute_reward_growths(reward_growths_global, upper_reward_growths_outside)
            )
        };

        (
            full_math_u128::wrapping_sub(full_math_u128::wrapping_sub(fee_growth_global_x, fee_growth_below_x), fee_growth_above_x),
            full_math_u128::wrapping_sub(full_math_u128::wrapping_sub(fee_growth_global_y, fee_growth_below_y), fee_growth_above_y),
            compute_reward_growths(compute_reward_growths(reward_growths_global, reward_growths_below), reward_growths_above)
        )
    }

    /// Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// @dev This function updates the tick information for the tick being updated, including liquidity, fee growths, reward growths, seconds per liquidity, tick cumulative, and seconds.
    /// @dev If the tick is being initialized, it sets the fee growths, reward growths, seconds per liquidity, tick cumulative, and seconds to the provided values.
    /// If the tick is being uninitialized, it clears the fee growths, reward growths, seconds per liquidity, tick cumulative, and seconds.
    /// @param self The mapping containing all tick information for initialized ticks.
    /// @param tick_index The index of the tick to update.
    /// @param tick_current_index The current tick index.
    /// @param liquidity_delta  A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left).
    /// @param fee_growth_global_x The all-time global fee growth, per unit of liquidity, in token X.
    /// @param fee_growth_global_y The all-time global fee growth, per unit of liquidity, in token Y.
    /// @param reward_growths_global The all-time global reward growths, per unit of liquidity, for each reward type.
    /// @param seconds_per_liquidity_cumulative The all-time seconds per max(1, liquidity) of the pool.
    /// @param tick_cumulative The tick * time elapsed since the pool was first initialized.
    /// @param timestamp_s The current timestamp in seconds.
    /// @param upper True for updating a position's upper tick, or false for updating a position's lower tick
    /// @param max_liquidity The maximum liquidity that can be added to the tick.
    /// @return Whether the tick was flipped from initialized to uninitialized, or vice versa.
    public(friend) fun update(
        self: &mut Table<I32, TickInfo>,
        tick_index: I32,
        tick_current_index: I32,
        liquidity_delta: I128,
        fee_growth_global_x: u128,
        fee_growth_global_y: u128,
        reward_growths_global: vector<u128>,
        seconds_per_liquidity_cumulative: u256,
        tick_cumulative: I64,
        timestamp_s: u64,
        upper: bool,
        max_liquidity: u128
    ): bool {
        let tick_info = try_borrow_mut_tick(self, tick_index);
        let liquidity_gross_before = tick_info.liquidity_gross;
        let liquidity_gross_after = liquidity_math::add_delta(liquidity_gross_before, liquidity_delta);

        if (liquidity_gross_after > max_liquidity) {
            abort E_LIQUIDITY_OVERFLOW
        };

        let flipped = (liquidity_gross_after == 0) != (liquidity_gross_before == 0);

        if (liquidity_gross_before == 0) {
            if (i32::lte(tick_index, tick_current_index)) {
                tick_info.fee_growth_outside_x = fee_growth_global_x;
                tick_info.fee_growth_outside_y = fee_growth_global_y;
                tick_info.seconds_per_liquidity_out_side = seconds_per_liquidity_cumulative;
                tick_info.tick_cumulative_out_side = tick_cumulative;
                tick_info.seconds_out_side = timestamp_s;
                tick_info.reward_growths_outside = reward_growths_global;
            } else {
                let (i, len) = (0, vector::length(&reward_growths_global));
                while(i < len) {
                    vector::push_back(&mut tick_info.reward_growths_outside, 0);
                    i = i + 1;
                };
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

    /// Clears a tick from the table.
    /// @param self The mapping containing all tick information for initialized ticks.
    /// @param tick The index of the tick to clear.
    public(friend) fun clear(self: &mut Table<I32, TickInfo>, tick: I32) {
        table::remove(self, tick);
    }

    /// Transitions to next tick as needed by price movement
    /// @dev This function updates the tick information for the tick being crossed, including fee growths, reward growths, seconds per liquidity, tick cumulative, and seconds.
    /// It returns the amount of liquidity added (subtracted) when the tick is crossed from left to right (right to left).
    /// @param self The mapping containing all tick information for initialized ticks.
    /// @param tick_index The index of the tick to cross.
    /// @param fee_growth_global_x The all-time global fee growth, per unit of liquidity, in token X.
    /// @param fee_growth_global_y The all-time global fee growth, per unit of liquidity, in token Y.
    /// @param reward_growths_global The all-time global reward growths, per unit of liquidity, for each reward type.
    /// @param seconds_per_liquidity_cumulative The all-time seconds per max(1, liquidity) of the pool.
    /// @param tick_cumulative The tick * time elapsed since the pool was first initialized.
    /// @param timestamp_s The current timestamp in seconds.
    /// @return  The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left).
    public(friend) fun cross(
        self: &mut Table<I32, TickInfo>,
        tick_index: I32,
        fee_growth_global_x: u128,
        fee_growth_global_y: u128,
        reward_growths_global: vector<u128>,
        seconds_per_liquidity_cumulative: u256,
        tick_cumulative: I64,
        timestamp_s: u64,
    ): I128 {
        let tick_info = try_borrow_mut_tick(self, tick_index);
        tick_info.fee_growth_outside_x = full_math_u128::wrapping_sub(fee_growth_global_x, tick_info.fee_growth_outside_x);
        tick_info.fee_growth_outside_y = full_math_u128::wrapping_sub(fee_growth_global_y, tick_info.fee_growth_outside_y);
        tick_info.reward_growths_outside = compute_reward_growths(reward_growths_global, tick_info.reward_growths_outside);
        tick_info.seconds_per_liquidity_out_side = seconds_per_liquidity_cumulative - tick_info.seconds_per_liquidity_out_side;
        tick_info.tick_cumulative_out_side = i64::sub(tick_cumulative, tick_info.tick_cumulative_out_side);
        tick_info.seconds_out_side = timestamp_s - tick_info.seconds_out_side;
        tick_info.liquidity_net
    }

    /// Computes the reward growths inside the tick range.
    /// @dev The reward growths inside the tick range are computed as the difference between the global reward growths and the reward growths outside the tick range.
    /// @dev If the reward growths outside the tick range are not available, they are assumed to be zero.
    /// @dev The function assumes that the length of `reward_growths_global` and `reward_growths_outside` are the same.
    /// @dev The function will panic if the lengths of `reward_growths_global` and `reward_growths_outside` are not the same.
    /// @param reward_growths_global The all-time global reward growths, per unit of liquidity, for each reward type.
    /// @param reward_growths_outside The reward growths outside the tick range.
    /// @return The reward growths inside the tick range.
    fun compute_reward_growths(reward_growths_global: vector<u128>, reward_growths_outside: vector<u128>): vector<u128> {
        let (i, len) = (0, vector::length(&reward_growths_global));
        let result = vector::empty<u128>();
        while(i < len) {
            let reward_growth_outside = if (i >= vector::length(&reward_growths_outside)) {
                0
            } else {
                *vector::borrow(&reward_growths_outside, i)
            };

            vector::push_back(
                &mut result,
                full_math_u128::wrapping_sub(*vector::borrow(&reward_growths_global, i), reward_growth_outside)
            );
            i = i + 1;
        };
        result
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
        let (fee_growth_inside_x, fee_growth_inside_y, reward_growths_inside) 
            = get_fee_and_reward_growths_inside(&ticks, i32::neg_from(2), i32::from(2), i32::zero(), 15, 15, vector<u128> [15, 15]);
        assert!(fee_growth_inside_x == 15 && fee_growth_inside_y == 15, 0);
        assert!(*vector::borrow(&reward_growths_inside, 0) == 15 && *vector::borrow(&reward_growths_inside, 1) == 15, 0);

        //returns 0 for two uninitialized ticks if tick is above
        let (fee_growth_inside_x, fee_growth_inside_y, reward_growths_inside) 
            = get_fee_and_reward_growths_inside(&ticks, i32::neg_from(2), i32::from(2), i32::from(4), 15, 15, vector<u128> [15, 15]);
        assert!(fee_growth_inside_x == 0 && fee_growth_inside_y == 0, 0);
        assert!(*vector::borrow(&reward_growths_inside, 0) == 0 && *vector::borrow(&reward_growths_inside, 1) == 0, 0);

        //returns 0 for two uninitialized ticks if tick is below
        let (fee_growth_inside_x, fee_growth_inside_y, reward_growths_inside) 
            = get_fee_and_reward_growths_inside(&ticks, i32::neg_from(2), i32::from(2), i32::neg_from(4), 15, 15, vector<u128> [15, 15]);
        assert!(fee_growth_inside_x == 0 && fee_growth_inside_y == 0, 0);
        assert!(*vector::borrow(&reward_growths_inside, 0) == 0 && *vector::borrow(&reward_growths_inside, 1) == 0, 0);

        //subtracts upper tick if below
        table::add(&mut ticks, i32::from(2), TickInfo {
            liquidity_gross: 0,
            liquidity_net: i128::zero(),
            fee_growth_outside_x: 2,
            fee_growth_outside_y: 3,
            reward_growths_outside: vector<u128> [4, 5],
            seconds_per_liquidity_out_side: 0,
            tick_cumulative_out_side: i64::zero(),
            seconds_out_side: 0
        });
        let (fee_growth_inside_x, fee_growth_inside_y, reward_growths_inside) 
            = get_fee_and_reward_growths_inside(&ticks, i32::neg_from(2), i32::from(2), i32::zero(), 15, 15, vector<u128> [15, 15]);
        assert!(fee_growth_inside_x == 13 && fee_growth_inside_y == 12, 0);
        assert!(*vector::borrow(&reward_growths_inside, 0) == 11 && *vector::borrow(&reward_growths_inside, 1) == 10, 0);

        //subtracts lower tick if above
        table::add(&mut ticks, i32::neg_from(2), TickInfo {
            liquidity_gross: 0,
            liquidity_net: i128::zero(),
            fee_growth_outside_x: 2,
            fee_growth_outside_y: 3,
            reward_growths_outside: vector<u128> [4, 5],
            seconds_per_liquidity_out_side: 0,
            tick_cumulative_out_side: i64::zero(),
            seconds_out_side: 0
        });
        let (fee_growth_inside_x, fee_growth_inside_y, reward_growths_inside) 
            = get_fee_and_reward_growths_inside(&ticks, i32::neg_from(2), i32::from(2), i32::zero(), 15, 15, vector<u128> [15, 15]);
        assert!(fee_growth_inside_x == 11 && fee_growth_inside_y == 9, 0);
        assert!(*vector::borrow(&reward_growths_inside, 0) == 7 && *vector::borrow(&reward_growths_inside, 1) == 5, 0);

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
        assert!(update(&mut ticks, i32::from(0), i32::from(0), i128::from(1), 0, 0, vector::empty(), 0, i64::zero(), 0, false, 3) == true, 0);

        //does not flip from nonzero to greater nonzero
        assert!(update(&mut ticks, i32::from(0), i32::from(0), i128::from(1), 0, 0, vector::empty(), 0, i64::zero(), 0, false, 3) == false, 0);

        //flips from nonzero to zero
        assert!(update(&mut ticks, i32::from(0), i32::from(0), i128::neg_from(2), 0, 0, vector::empty(), 0, i64::zero(), 0, false, 3) == true, 0);

        //does not flip from nonzero to lesser nonzero
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(2), 0, 0, vector::empty(), 0, i64::zero(), 0, false, 3);
        assert!(update(&mut ticks, i32::from(0), i32::from(0), i128::neg_from(1), 0, 0, vector::empty(), 0, i64::zero(), 0, false, 3) == false, 0);

        //nets the liquidity based on upper flag
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(2), 0, 0, vector::empty(), 0, i64::zero(), 0, false, 10);
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(1), 0, 0, vector::empty(), 0, i64::zero(), 0, true, 10);
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(3), 0, 0, vector::empty(), 0, i64::zero(), 0, true, 10);
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(1), 0, 0, vector::empty(), 0, i64::zero(), 0, false, 10);

        let (liquidity_gross, liquidity_net) = (get_liquidity_gross(&ticks, i32::from(0)), get_liquidity_net(&ticks, i32::from(0)));
        assert!(liquidity_gross == (1 + 2 + 1 + 3 + 1), 0);
        assert!(i128::eq(liquidity_net, i128::zero()), 0);

        //assumes all growth happens below ticks lte current tick
        update(&mut ticks, i32::from(1), i32::from(1), i128::from(1), 1, 2, vector<u128> [3, 4], 0, i64::zero(), 0, false, 10);
        assert!(is_initialized(&ticks, i32::from(1)), 0);
        let (liquidity_gross, liquidity_net) = (get_liquidity_gross(&ticks, i32::from(0)), get_liquidity_net(&ticks, i32::from(0)));
        let (fee_growth_outside_x, fee_growth_outside_y, reward_growths_outside) = get_fee_and_reward_growths_outside(&ticks, i32::from(1));
        assert!(liquidity_gross == (1 + 2 + 1 + 3 + 1), 0);
        assert!(i128::eq(liquidity_net, i128::zero()), 0);
        assert!(fee_growth_outside_x == 1 && fee_growth_outside_y == 2, 0);
        assert!(*vector::borrow(&reward_growths_outside, 0) == 3 && *vector::borrow(&reward_growths_outside, 1) == 4, 0);

        //does not set any growth fields if tick is already initialized
        update(&mut ticks, i32::from(1), i32::from(1), i128::from(1), 6, 7, vector<u128> [8, 9], 0, i64::zero(), 0, false, 10);
        let (fee_growth_outside_x, fee_growth_outside_y, reward_growths_outside) = get_fee_and_reward_growths_outside(&ticks, i32::from(1));
        assert!(fee_growth_outside_x == 1 && fee_growth_outside_y == 2, 0);
        assert!(*vector::borrow(&reward_growths_outside, 0) == 3 && *vector::borrow(&reward_growths_outside, 1) == 4, 0);

        //does not set any growth fields for ticks gt current tick
        update(&mut ticks, i32::from(2), i32::from(1), i128::from(1), 1, 2, vector<u128> [3, 4], 0, i64::zero(), 0, false, 10);
        let (liquidity_gross, liquidity_net) = (get_liquidity_gross(&ticks, i32::from(2)), get_liquidity_net(&ticks, i32::from(2)));
        let (fee_growth_outside_x, fee_growth_outside_y, reward_growths_outside) = get_fee_and_reward_growths_outside(&ticks, i32::from(2));
        assert!(liquidity_gross == 1, 0);
        assert!(i128::eq(liquidity_net, i128::from(1)), 0);
        assert!(fee_growth_outside_x == 0 && fee_growth_outside_y == 0, 0);
        assert!(*vector::borrow(&reward_growths_outside, 0) == 0 && *vector::borrow(&reward_growths_outside, 1) == 0, 0);

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

        update(&mut ticks, i32::from(0), i32::from(0), i128::from(2), 0, 0, vector::empty(), 0, i64::zero(), 0, false, 3);
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(1), 0, 0, vector::empty(), 0, i64::zero(), 0, true, 3);
        update(&mut ticks, i32::from(0), i32::from(0), i128::from(3), 0, 0, vector::empty(), 0, i64::zero(), 0, true, 3);
        
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
            fee_growth_outside_y: 4,
            reward_growths_outside: vector<u128> [8, 9],
            seconds_per_liquidity_out_side: 5,
            tick_cumulative_out_side: i64::from(6),
            seconds_out_side: 7
        });
        assert!(i128::eq(cross(&mut ticks, i32::from(2), 5, 7, vector<u128> [15, 17], 8, i64::from(15), 10), i128::from(2)), 0);
        let (fee_growth_outside_x, fee_growth_outside_y, reward_growths_outside) = get_fee_and_reward_growths_outside(&ticks, i32::from(2));
        let (seconds_per_liquidity_out_side, tick_cumulative_out_side, seconds_out_side) =
            (get_seconds_per_liquidity_out_side(&ticks, i32::from(2)), get_tick_cumulative_out_side(&ticks, i32::from(2)), get_seconds_out_side(&ticks, i32::from(2)));
        assert!(
            fee_growth_outside_x == 2 && fee_growth_outside_y == 3 && seconds_per_liquidity_out_side == 3 &&
            *vector::borrow(&reward_growths_outside, 0) == 7 && *vector::borrow(&reward_growths_outside, 1) == 8 &&
            i64::eq(tick_cumulative_out_side, i64::from(9)) && seconds_out_side == 3,
            0
        );

        //two flips are no op
        table::add(&mut ticks, i32::from(3), TickInfo {
            liquidity_gross: 3,
            liquidity_net: i128::from(4),
            fee_growth_outside_x: 1,
            fee_growth_outside_y: 2,
            reward_growths_outside: vector<u128> [3, 4],
            seconds_per_liquidity_out_side: 5,
            tick_cumulative_out_side: i64::from(6),
            seconds_out_side: 7
        });
        assert!(i128::eq(cross(&mut ticks, i32::from(3), 5, 7, vector<u128> [15, 17], 8, i64::from(15), 10), i128::from(4)), 0);
        assert!(i128::eq(cross(&mut ticks, i32::from(3), 5, 7, vector<u128> [15, 17], 8, i64::from(15), 10), i128::from(4)), 0);
        let (fee_growth_outside_x, fee_growth_outside_y, reward_growths_outside) = get_fee_and_reward_growths_outside(&ticks, i32::from(3));
        let (seconds_per_liquidity_out_side, tick_cumulative_out_side, seconds_out_side) =
            (get_seconds_per_liquidity_out_side(&ticks, i32::from(3)), get_tick_cumulative_out_side(&ticks, i32::from(3)), get_seconds_out_side(&ticks, i32::from(3)));
        assert!(
            fee_growth_outside_x == 1 && fee_growth_outside_y == 2 && seconds_per_liquidity_out_side == 5 &&
            *vector::borrow(&reward_growths_outside, 0) == 3 && *vector::borrow(&reward_growths_outside, 1) == 4 &&
            i64::eq(tick_cumulative_out_side, i64::from(6)) && seconds_out_side == 7,
            0
        );

        table::drop(ticks);
    }
}