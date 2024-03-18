module flowx_clmm::admin_cap {
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;

    struct AdminCap has key, store {
        id: UID
    }

    fun init(ctx: &mut TxContext) {
        transfer::transfer(AdminCap {
            id: object::new(ctx)
        }, tx_context::sender(ctx));
    }

    #[test_only]
    public fun create_for_testing(ctx: &mut TxContext): AdminCap {
        AdminCap {
            id: object::new(ctx)
        }
    }

    #[test_only]
    public fun destroy_for_testing(admin_cap: AdminCap) {
        let AdminCap { id } = admin_cap;
        object::delete(id);
    }
}