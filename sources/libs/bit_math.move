module flowx_clmm::bit_math {
    use flowx_clmm::constants;

    const E_UNDERFLOW: u64 = 0;

    /// Returns the index of the most significant bit of the number,
    ///     where the least significant bit is at index 0 and the most significant bit is at index 255
    /// The function satisfies the property:
    ///     x >= 2**get_most_significant_bit(x) and x < 2**(get_most_significant_bit(x)+1)
    /// @param x the value for which to compute the most significant bit, must be greater than 0
    /// @return the index of the most significant bit
    public fun get_most_significant_bit(x: u256): u8 {
        assert!(x > 0, E_UNDERFLOW);

        let r = 0;
        if (x >= 0x100000000000000000000000000000000) {
            x = x >> 128;
            r = r + 128;
        };
        if (x >= 0x10000000000000000) {
            x = x >> 64;
            r = r + 64;
        };
        if (x >= 0x100000000) {
            x = x >> 32;
            r = r + 32;
        };
        if (x >= 0x10000) {
            x = x >> 16;
            r = r + 16;
        };
        if (x >= 0x100) {
            x = x >> 8;
            r = r + 8;
        };
        if (x >= 0x10) {
            x = x >> 4;
            r = r + 4;
        };
        if (x >= 0x4) {
            x = x >> 2;
            r = r + 2;
        };
        if (x >= 0x2) {
            r = r + 1;
        };

        r
    }

    /// Returns the index of the least significant bit of the number,
    ///     where the least significant bit is at index 0 and the most significant bit is at index 255
    /// The function satisfies the property:
    ///     (x & 2**get_least_significant_bit(x)) != 0 and (x & (2**(get_least_significant_bit(x)) - 1)) == 0)
    /// @param x the value for which to compute the least significant bit, must be greater than 0
    /// @return r the index of the least significant bit
    public fun get_least_significant_bit(x: u256): u8 {
        assert!(x > 0, E_UNDERFLOW);

        let r = 255;
        if (x & (constants::get_max_u128() as u256) > 0) {
            r = r - 128;
        } else {
            x = x >> 128;
        };

        if (x & (constants::get_max_u64() as u256) > 0) {
            r = r - 64;
        } else {
            x = x >> 64;
        };

        if (x & (constants::get_max_u32() as u256) > 0) {
            r = r - 32;
        } else {
            x = x >> 32;
        };

        if (x & (constants::get_max_u16() as u256) > 0) {
            r = r - 16;
        } else {
            x = x >> 16;
        };

        if (x & (constants::get_max_u8() as u256) > 0) {
            r = r - 8;
        } else {
            x = x >> 8;
        };

        if (x & 0xf > 0) {
            r = r - 4;
        } else {
            x = x >> 4;
        };

        if (x & 0x3 > 0) {
            r = r - 2;
        } else {
            x = x >> 2;
        };

        if (x & 0x1 > 0) {
            r = r - 1;
        };

        r
    }

    #[test]
    public fun test_get_most_significant_bit() {
        assert!(get_most_significant_bit(1) == 0, 0);
        assert!(get_most_significant_bit(2) == 1, 0);

        //All powers of 2
        let i = 0;
        while(i < 255) {
            assert!(get_most_significant_bit(flowx_clmm::test_utils::pow(2, i)) == i, 0);
            i = i + 1;
        };

        //uint256 max
        assert!(get_most_significant_bit(flowx_clmm::constants::get_max_u256()) == 255, 0);
    }

    #[test]
    #[expected_failure(abort_code = E_UNDERFLOW)]
    public fun test_get_most_significant_bit_failed_if_number_zero() {
        assert!(get_most_significant_bit(0) == 0, 0);
    }

    #[test]
    public fun test_get_least_significant_bit() {
        assert!(get_least_significant_bit(1) == 0, 0);
        assert!(get_least_significant_bit(2) == 1, 0);

        //All powers of 2
        let i = 0;
        while(i < 255) {
            assert!(get_least_significant_bit(flowx_clmm::test_utils::pow(2, i)) == i, 0);
            i = i + 1;
        };

        //uint256 max
        assert!(get_least_significant_bit(flowx_clmm::constants::get_max_u256()) == 0, 0);
    }
}