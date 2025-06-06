module flowx_clmm::versioned {
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use sui::dynamic_field::{Self as df};

    use flowx_clmm::admin_cap::AdminCap;
    friend flowx_clmm::pool;
    friend flowx_clmm::pool_manager;
    friend flowx_clmm::position_manager;

    const VERSION: u64 = 4;

    const E_WRONG_VERSION: u64 = 999;
    const E_NOT_UPGRADED: u64 = 1000;
    const E_ALREADY_PAUSED: u64 = 1001;
    const E_NOT_PAUSED: u64 = 1002;

    struct GlobalPauseDfKey has copy, drop, store {}

    struct Versioned has key, store {
        id: UID,
        version: u64
    }

    struct Upgraded has copy, drop, store {
        previous_version: u64,
        new_version: u64
    }

    struct Paused has copy, drop, store {
        sender: address
    }

    struct Unpaused has copy, drop, store {
        sender: address
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

    public fun check_pause(self: &Versioned) {
        if (is_paused(self)) {
            abort E_ALREADY_PAUSED
        }
    }

    public fun upgrade(_: &AdminCap, self: &mut Versioned) {
        assert!(self.version < VERSION, E_NOT_UPGRADED);
        ugrade_internal(self);
    }
    

    public entry fun pause(_: &AdminCap, self: &mut Versioned, ctx: &TxContext) {
        check_version(self);
        if (df::exists_with_type<GlobalPauseDfKey, bool>(&self.id, GlobalPauseDfKey {})) {
            let is_paused_val = df::borrow_mut<GlobalPauseDfKey, bool>(&mut self.id, GlobalPauseDfKey {});
            assert!(*is_paused_val == false, E_ALREADY_PAUSED);
            *is_paused_val = true;
        } else {
            df::add<GlobalPauseDfKey, bool>(&mut self.id, GlobalPauseDfKey {}, true);
        };

        event::emit(Paused {
            sender: tx_context::sender(ctx)
        });
    }

    public entry fun unpause(_: &AdminCap, self: &mut Versioned, ctx: &TxContext) {
        check_version(self);
        if (df::exists_with_type<GlobalPauseDfKey, bool>(&self.id, GlobalPauseDfKey {})) {
            let is_paused_val = df::borrow_mut<GlobalPauseDfKey, bool>(&mut self.id, GlobalPauseDfKey {});
            assert!(*is_paused_val == true, E_NOT_PAUSED);
            *is_paused_val = false;
        } else {
            abort E_NOT_PAUSED;
        };

        event::emit(Unpaused {
            sender: tx_context::sender(ctx)
        });
    }

    public fun is_paused(self: &Versioned): bool {
        let is_paused = if (df::exists_with_type<GlobalPauseDfKey, bool>(&self.id, GlobalPauseDfKey {})) {
            let is_paused_val = df::borrow<GlobalPauseDfKey, bool>(&self.id, GlobalPauseDfKey {});
            *is_paused_val
        } else {
            false
        };

        is_paused
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

    #[test_only]
    public fun pause_for_testing(self: &mut Versioned) {
        df::add<GlobalPauseDfKey, bool>(&mut self.id, GlobalPauseDfKey {}, true);
    }

    #[test_only]
    public fun unpause_for_testing(self: &mut Versioned) {
        let is_paused_val = df::borrow_mut<GlobalPauseDfKey, bool>(&mut self.id, GlobalPauseDfKey {});
        *is_paused_val = false;
    }
}

#[test_only]
module flowx_clmm::versioned_test {
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use sui::dynamic_field::{Self as df};

    use flowx_clmm::versioned;

    #[test]
    public fun test_pause() {
        let ctx = tx_context::dummy();
        let versioned = versioned::create_for_testing(&mut ctx);
        versioned::pause_for_testing(&mut versioned);
        assert!(versioned::is_paused(&versioned) == true, 0);

        versioned::destroy_for_testing(versioned);
    }

    #[test]
    public fun test_unpause() {
        let ctx = tx_context::dummy();
        let versioned = versioned::create_for_testing(&mut ctx);
        versioned::pause_for_testing(&mut versioned);
        assert!(versioned::is_paused(&versioned) == true, 0);
        versioned::unpause_for_testing(&mut versioned);
        assert!(versioned::is_paused(&versioned) == false, 0);

        versioned::destroy_for_testing(versioned);
    }
}