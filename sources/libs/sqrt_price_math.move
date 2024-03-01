module flowx_clmm::sqrt_price_math {
    use flowx_clmm::full_math_u128;
    use flowx_clmm::math_u256;
    use flowx_clmm::tick_math;
    use flowx_clmm::constants;

    const E_OVERFLOW: u64 = 0;
    const E_INVALID_PRICE: u64 = 1;
    const E_PRICE_OVERFLOW: u64 = 2;
    const E_NOT_ENOUGH_LIQUIDITY: u64 = 3;
    const E_INVALID_PRICE_OR_LIQUIDITY: u64 = 4;

    public fun get_next_sqrt_price_from_amount_x_rouding_up(
        sqrt_price: u128,
        liquidity: u128,
        amount: u64,
        add: bool
    ): u128 {
        if (amount == 0) {
            return sqrt_price
        };
    
        let (numberator, overflowing) = math_u256::checked_shlw(
            full_math_u128::full_mul(sqrt_price, liquidity)
        );
        if (overflowing) {
            abort E_OVERFLOW
        };

        let liquidity_shl_64 = (liquidity as u256) << 64;
        let product = full_math_u128::full_mul(sqrt_price, (amount as u128));
        let new_sqrt_price = if (add) {
            (math_u256::div_round(numberator, (liquidity_shl_64 + product), true) as u128)
        } else {
            if (liquidity_shl_64 <= product) {
                abort E_PRICE_OVERFLOW
            };
            (math_u256::div_round(numberator, (liquidity_shl_64 - product), true) as u128)
        };

        if (new_sqrt_price > tick_math::max_sqrt_price() || new_sqrt_price < tick_math::min_sqrt_price()) {
            abort E_PRICE_OVERFLOW
        };

        new_sqrt_price
    }

    public fun get_next_sqrt_price_from_amount_y_rouding_down(
        sqrt_price: u128,
        liquidity: u128,
        amount: u64,
        add: bool
    ): u128 {
        let quotient = (math_u256::div_round(((amount as u256) << 64), (liquidity as u256), !add) as u128);
        let new_sqrt_price = if (add) {
            sqrt_price + quotient
        } else {
            if (sqrt_price <= quotient) {
                abort E_NOT_ENOUGH_LIQUIDITY
            };
            sqrt_price - quotient
        };

        if (new_sqrt_price > tick_math::max_sqrt_price() || new_sqrt_price < tick_math::min_sqrt_price()) {
            abort E_PRICE_OVERFLOW
        };

        new_sqrt_price
    }

    public fun get_next_sqrt_price_from_input(
        sqrt_price: u128,
        liquidity: u128,
        amount_in: u64,
        x_for_y: bool
    ): u128 {
        assert!(sqrt_price > 0 && liquidity > 0, E_INVALID_PRICE_OR_LIQUIDITY);

        if (x_for_y) {
            get_next_sqrt_price_from_amount_x_rouding_up(sqrt_price, liquidity, amount_in, true)
        } else {
            get_next_sqrt_price_from_amount_y_rouding_down(sqrt_price, liquidity, amount_in, true)
        }
    }

    public fun get_next_sqrt_price_from_output(
        sqrt_price: u128,
        liquidity: u128,
        amount_out: u64,
        x_for_y: bool
    ): u128 {
        assert!(sqrt_price > 0 && liquidity > 0, E_INVALID_PRICE_OR_LIQUIDITY);

        if (x_for_y) {
            get_next_sqrt_price_from_amount_y_rouding_down(sqrt_price, liquidity, amount_out, false)
        } else {
            get_next_sqrt_price_from_amount_x_rouding_up(sqrt_price, liquidity, amount_out, false)
        }
    }

    public fun get_amount_x_delta(
        sqrt_ratio_0: u128,
        sqrt_ratio_1: u128,
        liquidity: u128,
        round_up: bool
    ): u64 {
        if (sqrt_ratio_0 == 0 || sqrt_ratio_1 == 0) {
            abort E_INVALID_PRICE
        };

        let sqrt_ratio_diff = if (sqrt_ratio_0 > sqrt_ratio_1) {
            (sqrt_ratio_0 - sqrt_ratio_1)
        } else {
            (sqrt_ratio_1 - sqrt_ratio_0)
        };

        if (sqrt_ratio_diff == 0 || liquidity == 0) {
            return 0
        };

        let (numerator, overflowing) = math_u256::checked_shlw(
            full_math_u128::full_mul(liquidity, sqrt_ratio_diff)
        );

        if (overflowing) {
            abort E_OVERFLOW
        };

        let denominator = full_math_u128::full_mul(sqrt_ratio_0, sqrt_ratio_1);
        (math_u256::div_round(numerator, denominator, round_up) as u64)
    }

    public fun get_amount_y_delta(
        sqrt_ratio_0: u128,
        sqrt_ratio_1: u128,
        liquidity: u128,
        round_up: bool
    ): u64 {
        let sqrt_ratio_diff = if (sqrt_ratio_0 > sqrt_ratio_1) {
            (sqrt_ratio_0 - sqrt_ratio_1)
        } else {
            (sqrt_ratio_1 - sqrt_ratio_0)
        };

        if (sqrt_ratio_diff == 0 || liquidity == 0) {
            return 0
        };

        (
            math_u256::div_round(
                full_math_u128::full_mul(liquidity, sqrt_ratio_diff),
                (constants::get_q64() as u256),
                round_up
            ) as u64
        )
    }

    #[test]
    fun test_get_amount_x_delta() {
        use flowx_clmm::test_utils;

        assert!(
            get_amount_x_delta(
                test_utils::encode_sqrt_price(1, 1), test_utils::encode_sqrt_price(2, 1), 0, true
            ) == 0,
            0
        );

        assert!(
            get_amount_x_delta(
                test_utils::encode_sqrt_price(1, 1), test_utils::encode_sqrt_price(1, 1), 0, true
            ) == 0,
            0
        );

        assert!(
            get_amount_x_delta(
                test_utils::encode_sqrt_price(1, 1),
                test_utils::encode_sqrt_price(121, 100),
                (flowx_clmm::test_utils::expand_to_9_decimals(1) as u128),
                true
            ) == 90909091,
            0
        );
        assert!(
            get_amount_x_delta(
                test_utils::encode_sqrt_price(1, 1),
                test_utils::encode_sqrt_price(121, 100),
                (flowx_clmm::test_utils::expand_to_9_decimals(1) as u128),
                false
            ) == 90909090,
            0
        );

        let amount_up = get_amount_x_delta(
            test_utils::encode_sqrt_price((test_utils::pow(2, 60) as u64), 1),
            test_utils::encode_sqrt_price((test_utils::pow(2, 63) as u64), 1),
            (flowx_clmm::test_utils::expand_to_9_decimals(1) as u128),
            true
        );
        let amount_down = get_amount_x_delta(
            test_utils::encode_sqrt_price((test_utils::pow(2, 60) as u64), 1),
            test_utils::encode_sqrt_price((test_utils::pow(2, 63) as u64), 1),
            (flowx_clmm::test_utils::expand_to_9_decimals(1) as u128),
            false
        );
        assert!(amount_up == amount_down + 1, 0);
    }

    #[test]
    fun test_get_amount_y_delta() {
        use flowx_clmm::test_utils;

        assert!(
            get_amount_y_delta(
                test_utils::encode_sqrt_price(1, 1), test_utils::encode_sqrt_price(2, 1), 0, true
            ) == 0,
            0
        );

        assert!(
            get_amount_y_delta(
                test_utils::encode_sqrt_price(1, 1), test_utils::encode_sqrt_price(1, 1), 0, true
            ) == 0,
            0
        );

        assert!(
            get_amount_y_delta(
                test_utils::encode_sqrt_price(1, 1),
                test_utils::encode_sqrt_price(121, 100),
                (flowx_clmm::test_utils::expand_to_9_decimals(1) as u128),
                true
            ) == 100000000,
            0
        );
        assert!(
            get_amount_y_delta(
                test_utils::encode_sqrt_price(1, 1),
                test_utils::encode_sqrt_price(121, 100),
                (flowx_clmm::test_utils::expand_to_9_decimals(1) as u128),
                false
            ) == 99999999,
            0
        );
    }

    #[test]
    public fun test_get_next_sqrt_price_from_input() {
        use flowx_clmm::test_utils;
        use flowx_clmm::constants;

        let price = test_utils::encode_sqrt_price(1, 1);
        assert!(get_next_sqrt_price_from_input(price, 1, 0, true) == price, 0);
        assert!(get_next_sqrt_price_from_input(price, 1, 0, false) == price, 0);

        let liquidity = test_utils::expand_to_9_decimals(1);
        let amount = test_utils::expand_to_9_decimals(1) / 10;
        assert!(get_next_sqrt_price_from_input(price, (liquidity as u128), amount, false) == 20291418481080506777, 0);
        assert!(get_next_sqrt_price_from_input(price, (liquidity as u128), amount, true) == 16769767339735956015, 0);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_PRICE_OR_LIQUIDITY)]
    public fun test_get_next_price_from_input_failed_if_price_is_zero() {
        get_next_sqrt_price_from_input(0, 1, 1, false);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_PRICE_OR_LIQUIDITY)]
    public fun test_get_next_price_from_input_failed_if_liquidity_is_zero() {
        get_next_sqrt_price_from_input(1, 0, 1, false);
    }

    #[test]
    public fun test_get_next_sqrt_price_from_output() {
        use flowx_clmm::test_utils;
        use flowx_clmm::constants;

        let price = 4722366482869645213696;
        let liquidity = 1024;
        let amount_out = 262143;
        assert!(get_next_sqrt_price_from_output(price, liquidity, amount_out, true) == 18014398509481984, 0);

        let price = test_utils::encode_sqrt_price(1, 1);
        let liquidity = (test_utils::expand_to_9_decimals(1) as u128) / 10;
        assert!(get_next_sqrt_price_from_output(price, liquidity, 0, true) == price, 0);
        assert!(get_next_sqrt_price_from_output(price, liquidity, 0, false) == price, 0);

        let liquidity = (test_utils::expand_to_9_decimals(1) as u128);
        let amount = test_utils::expand_to_9_decimals(1) / 10;
        assert!(get_next_sqrt_price_from_output(price, liquidity, amount, false) == 20496382304121724018, 0);
        assert!(get_next_sqrt_price_from_output(price, liquidity, amount, true) == 16602069666338596454, 0);

        let price = 4722366482869645213696;
        let liquidity = 1024;
        let amount_out = 262143;
        assert!(get_next_sqrt_price_from_output(price, liquidity, amount_out, true) == 18014398509481984, 0);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_PRICE_OR_LIQUIDITY)]
    public fun test_get_next_price_from_output_failed_if_price_is_zero() {
        get_next_sqrt_price_from_output(0, 1, 1, false);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_PRICE_OR_LIQUIDITY)]
    public fun test_get_next_price_from_output_failed_if_liquidity_is_zero() {
        get_next_sqrt_price_from_output(1, 0, 1, false);
    }

    #[test]
    #[expected_failure(abort_code = E_NOT_ENOUGH_LIQUIDITY)]
    public fun test_get_next_price_from_output_failed_if_not_enough_liquidity() {
        use flowx_clmm::test_utils;
        use flowx_clmm::constants;

        let price = test_utils::encode_sqrt_price(1, 1);
        let liquidity = 1;
        let amount = constants::get_max_u64();
        get_next_sqrt_price_from_output(price, liquidity, amount, true);
    }

    #[test]
    #[expected_failure(abort_code = E_PRICE_OVERFLOW)]
    public fun test_get_next_price_from_input_failed_if_output_amount_is_exactly_the_virtual_resereves_of_x() {
        let price = 4722366482869645213696;
        let liquidity = 1024;
        let amount_out = 4;
        get_next_sqrt_price_from_output(price, liquidity, amount_out, false);
    }

    #[test]
    #[expected_failure(abort_code = E_PRICE_OVERFLOW)]
    public fun test_get_next_price_from_input_failed_if_output_amount_gt_the_virtual_resereves_of_x() {
        let price = 4722366482869645213696;
        let liquidity = 1024;
        let amount_out = 5;
        get_next_sqrt_price_from_output(price, liquidity, amount_out, false);
    }

    #[test]
    #[expected_failure(abort_code = E_NOT_ENOUGH_LIQUIDITY)]
    public fun test_get_next_price_from_input_failed_if_output_amount_gt_the_virtual_resereves_of_y() {
        let price = 4722366482869645213696;
        let liquidity = 1024;
        let amount_out = 262145;
        get_next_sqrt_price_from_output(price, liquidity, amount_out, true);
    }

    #[test]
    #[expected_failure(abort_code = E_NOT_ENOUGH_LIQUIDITY)]
    public fun test_get_next_price_from_input_failed_if_output_amount_is_exactly_the_virtual_resereves_of_y() {
        let price = 4722366482869645213696;
        let liquidity = 1024;
        let amount_out = 262144;
        get_next_sqrt_price_from_output(price, liquidity, amount_out, true);
    }
}