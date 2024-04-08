module flowx_clmm::swap_math {
    use flowx_clmm::constants;
    use flowx_clmm::full_math_u64;
    use flowx_clmm::sqrt_price_math;
    
    #[allow(unused_assignment)]
    public fun compute_swap_step(
        sqrt_ratio_current: u128,
        sqrt_ratio_target: u128,
        liquidity: u128,
        amount_remaining: u64,
        fee_rate: u64,
        exact_in: bool
    ): (u128, u64, u64, u64) {
        let x_for_y = sqrt_ratio_current >= sqrt_ratio_target;
        
        let amount_in = 0;
        let amount_out = 0;
        let fee_amount = 0;
        let sqrt_ratio_next = 0;
        if (exact_in) {
            let amount_remaining_less_fee = full_math_u64::mul_div_floor(
                amount_remaining,
                constants::get_fee_rate_denominator_value() - fee_rate,
                constants::get_fee_rate_denominator_value()
            );
            amount_in = if (x_for_y) {
                sqrt_price_math::get_amount_x_delta(sqrt_ratio_target, sqrt_ratio_current, liquidity, true)
            } else {
                sqrt_price_math::get_amount_y_delta(sqrt_ratio_current, sqrt_ratio_target, liquidity, true)
            };
            sqrt_ratio_next = if (amount_remaining_less_fee >= amount_in) {
                sqrt_ratio_target
            } else {
                sqrt_price_math::get_next_sqrt_price_from_input(
                    sqrt_ratio_current,
                    liquidity,
                    amount_remaining_less_fee,
                    x_for_y
                )
            };
        } else {
            amount_out = if (x_for_y) {
                sqrt_price_math::get_amount_y_delta(sqrt_ratio_target, sqrt_ratio_current, liquidity, false)
            } else {
                sqrt_price_math::get_amount_x_delta(sqrt_ratio_current, sqrt_ratio_target, liquidity, false)
            };

            sqrt_ratio_next = if (amount_remaining >= amount_out) {
                sqrt_ratio_target
            } else {
                sqrt_price_math::get_next_sqrt_price_from_output(
                    sqrt_ratio_current,
                    liquidity,
                    amount_remaining,
                    x_for_y
                )
            };
        };

        let max = sqrt_ratio_target == sqrt_ratio_next;

        if (x_for_y) {
            amount_in = if (max && exact_in) {
                amount_in
            } else {
                sqrt_price_math::get_amount_x_delta(sqrt_ratio_next, sqrt_ratio_current, liquidity, true)
            };
            amount_out = if (max && !exact_in) {
                amount_out
            } else {
                sqrt_price_math::get_amount_y_delta(sqrt_ratio_next, sqrt_ratio_current, liquidity, false)
            };
        } else {
            amount_in = if (max && exact_in) {
                amount_in
            } else {
                sqrt_price_math::get_amount_y_delta(sqrt_ratio_current, sqrt_ratio_next, liquidity, true)
            };
            amount_out = if (max && !exact_in) {
                amount_out
            } else {
                sqrt_price_math::get_amount_x_delta(sqrt_ratio_current, sqrt_ratio_next, liquidity, false)
            };
        };

        if (!exact_in && amount_out > amount_remaining) {
            amount_out = amount_remaining;
        };

        fee_amount = if (exact_in && sqrt_ratio_next != sqrt_ratio_target) {
            amount_remaining - amount_in
        } else {
            full_math_u64::mul_div_round(amount_in, fee_rate, constants::get_fee_rate_denominator_value() - fee_rate)
        };

        (sqrt_ratio_next, amount_in, amount_out, fee_amount)
    }

    #[test]
    public fun test_compute_swap_step() {
        use flowx_clmm::test_utils;
        use flowx_clmm::sqrt_price_math;

        //exact amount in that gets capped at price target in one for zero
        let price = test_utils::encode_sqrt_price(1, 1);
        let price_target = test_utils::encode_sqrt_price(101, 100);
        let liquidity = test_utils::expand_to_9_decimals(2);
        let amount = test_utils::expand_to_9_decimals(1);
        let fee = 600;
        let x_for_y = false;
        let exact_in = true;

        let (sqrt_price_next, amount_in, amount_out, fee_amount) = compute_swap_step(
            price,
            price_target,
            (liquidity as u128),
            amount,
            fee,
            exact_in
        );
        assert!(amount_in == 9975125, 0);
        assert!(fee_amount == 5989, 0);
        assert!(amount_out == 9925619, 0);
        assert!(amount_in + fee_amount < amount, 0);
        let price_after = sqrt_price_math::get_next_sqrt_price_from_input(
            price,
            (liquidity as u128),
            amount,
            x_for_y
        );
        assert!(sqrt_price_next == price_target, 0);
        assert!(sqrt_price_next < price_after, 0);

        //exact amount out that gets capped at price target in one for zero
        let price = test_utils::encode_sqrt_price(1, 1);
        let price_target = test_utils::encode_sqrt_price(101, 100);
        let liquidity = test_utils::expand_to_9_decimals(2);
        let amount = test_utils::expand_to_9_decimals(1);
        let fee = 600;
        let x_for_y = false;
        let exact_in = false;

        let (sqrt_price_next, amount_in, amount_out, fee_amount) = compute_swap_step(
            price,
            price_target,
            (liquidity as u128),
            amount,
            fee,
            exact_in
        );
        assert!(amount_in == 9975125, 0);
        assert!(fee_amount == 5989, 0);
        assert!(amount_out == 9925619, 0);
        assert!(amount_out < amount, 0);
        let price_after = sqrt_price_math::get_next_sqrt_price_from_input(
            price,
            (liquidity as u128),
            amount,
            x_for_y
        );
        assert!(sqrt_price_next == price_target, 0);
        assert!(sqrt_price_next < price_after, 0);

        //exact amount in that is fully spent in one for zero
        let price = test_utils::encode_sqrt_price(1, 1);
        let price_target = test_utils::encode_sqrt_price(1000, 100);
        let liquidity = test_utils::expand_to_9_decimals(2);
        let amount = test_utils::expand_to_9_decimals(1);
        let fee = 600;
        let x_for_y = false;
        let exact_in = true;

        let (sqrt_price_next, amount_in, amount_out, fee_amount) = compute_swap_step(
            price,
            price_target,
            (liquidity as u128),
            amount,
            fee,
            exact_in
        );
        assert!(amount_in == 999400000, 0);
        assert!(fee_amount == 600000, 0);
        assert!(amount_out == 666399946, 0);
        assert!(amount_in + fee_amount == amount, 0);
        let price_after = sqrt_price_math::get_next_sqrt_price_from_input(
            price,
            (liquidity as u128),
            amount - fee_amount,
            x_for_y
        );
        assert!(sqrt_price_next < price_target, 0);
        assert!(sqrt_price_next == price_after, 0);

        //amount out is capped at the desired amount out
        let (sqrt_price_next, amount_in, amount_out, fee_amount) = compute_swap_step(
            97167715013977308122856,
            338272718368148901,
            8638091619,
            1,
            1,
            false
        );
        assert!(amount_in == 1, 0);
        assert!(fee_amount == 0, 0);
        assert!(amount_out == 1, 0);
        assert!(sqrt_price_next == 97167715013975172611346, 0);

        //handles intermediate insufficient liquidity in zero for one exact output case
        let price = 4722366482869645213696;
        let price_target = price * 11 / 10;
        let (sqrt_price_next, amount_in, amount_out, fee_amount) = compute_swap_step(
            price,
            price_target,
            1024,
            4,
            3000,
            false
        );
        assert!(amount_in == 26215, 0);
        assert!(fee_amount == 79, 0);
        assert!(amount_out == 0, 0);
        assert!(sqrt_price_next == price_target, 0);

        //handles intermediate insufficient liquidity in zero for one exact output case
        let price = 4722366482869645213696;
        let price_target = price * 9 / 10;
        let (sqrt_price_next, amount_in, amount_out, fee_amount) = compute_swap_step(
            price,
            price_target,
            1024,
            263000,
            3000,
            false
        );
        assert!(amount_in == 1, 0);
        assert!(fee_amount == 0, 0);
        assert!(amount_out == 26214, 0);
        assert!(sqrt_price_next == price_target, 0);
    }
}