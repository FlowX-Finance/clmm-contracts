// Copied from: https://github.com/CetusProtocol/integer-mate/blob/main/sui/sources/math_u256.move
module flowx_clmm::math_u256 {
    const MAX_U256: u256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    
    const E_DIV_BY_ZERO: u64 = 1;

    public fun div_mod(num: u256, denom: u256): (u256, u256) {
        let p = num / denom;
        let r: u256 = num - (p * denom);
        (p, r)
    }

    public fun shlw(n: u256): u256 {
        n << 64
    }

    public fun shrw(n: u256): u256 {
        n >> 64
    }

    public fun checked_shlw(n: u256): (u256, bool) {
        let mask = 0xffffffffffffffff << 192;
        if (n > mask) {
            (0, true)
        } else {
            ((n << 64), false)
        }
    }

    public fun div_round(num: u256, denom: u256, round_up: bool): u256 {
        if (denom == 0) {
            abort E_DIV_BY_ZERO
        };

        let p = num / denom;
        if (round_up && ((p * denom) != num)) {
            p + 1
        } else {
            p
        }
    }

    public fun add_check(num1: u256, num2: u256): bool {
        (MAX_U256 - num1 >= num2)
    }

    public fun overflow_add(num1: u256, num2: u256): u256 {
        if (!add_check(num1, num2)) {
            let diff = MAX_U256 - num1;
            num2 - diff - 1
        } else {
            num1 + num2
        }
    }

    #[test]
    fun test_div_round() {
        div_round(1, 1, true);
    }

    #[test]
    fun test_add() {
        1000u256 + 1000u256;
    }

    #[test]
    fun test_overflow_add() {
        assert!(overflow_add(MAX_U256, 1) == 0, 0);
        assert!(overflow_add(MAX_U256, 100) == 99, 0);
        assert!(overflow_add(MAX_U256 - 100, 100) == MAX_U256, 0);
        assert!(overflow_add(MAX_U256 - 200, 100) == MAX_U256 - 100, 0);
    }
}
