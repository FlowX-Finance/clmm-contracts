module flowx_clmm::utils {
    use std::type_name;
    use std::ascii;
    use sui::tx_context::TxContext;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::transfer;

    use flowx_clmm::comparator;

    const E_EXPIRED: u64 = 0;
    const E_IDENTICAL_COIN: u64 = 1;

    public fun check_deadline(clock: &Clock, deadline: u64) {
        if (deadline < clock::timestamp_ms(clock)) {
            abort E_EXPIRED
        }
    }

    public fun is_ordered<X, Y>(): bool {
        let x_name = type_name::into_string(type_name::get<X>());
        let y_name = type_name::into_string(type_name::get<Y>());

        let result = comparator::compare_u8_vector(ascii::into_bytes(x_name), ascii::into_bytes(y_name));
        assert!(!comparator::is_equal(&result), E_IDENTICAL_COIN);
        
        comparator::is_smaller_than(&result)
    }

    public fun to_seconds(ms: u64): u64 {
        ms / 1000
    }

    #[lint_allow(self_transfer)]
    public fun refund<X>(
        refunded: Coin<X>,
        receipt: address
    ) {
        if (coin::value(&refunded) > 0) {
            transfer::public_transfer(refunded, receipt);
        } else {
            coin::destroy_zero(refunded)
        }; 
    }
}