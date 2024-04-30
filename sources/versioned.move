module flowx_clmm::versioned {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::event;

    use flowx_clmm::admin_cap::AdminCap;
    friend flowx_clmm::pool;
    friend flowx_clmm::pool_manager;
    friend flowx_clmm::position_manager;

    const VERSION: u64 = 1;

    const E_WRONG_VERSION: u64 = 999;
    const E_NOT_UPGRADED: u64 = 1000;

    struct Versioned has key, store {
        id: UID,
        version: u64
    }

    struct Upgraded has copy, drop, store {
        previous_version: u64,
        new_version: u64
    }

    fun init(ctx: &mut TxContext) {
        transfer::share_object(Versioned {
            id: object::new(ctx),
            version: VERSION
        });
    }

    public fun check_version(self: &Versioned) {
        if (self.version != VERSION) {
            abort E_WRONG_VERSION
        }
    }

    public(friend) fun check_version_and_upgrade(self: &mut Versioned) {
        if (self.version < VERSION) {
            ugrade_internal(self);
        };
        check_version(self);
    }

    public fun upgrade(_: &AdminCap, self: &mut Versioned) {
        assert!(self.version < VERSION, E_NOT_UPGRADED);
        ugrade_internal(self);
    }

    fun ugrade_internal(self: &mut Versioned) {
        event::emit(Upgraded {
            previous_version: self.version,
            new_version: VERSION
        });
        self.version = VERSION;
    }

    #[test_only]
    public fun create_for_testing(ctx: &mut TxContext): Versioned {
        Versioned {
            id: object::new(ctx),
            version: VERSION
        }
    }

    #[test_only]
    public fun destroy_for_testing(versioned: Versioned) {
        let Versioned { id, version: _ } = versioned;
        object::delete(id); 
    }
}