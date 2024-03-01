module flowx_clmm::versioned {
    use sui::object::{Self, UID};

    friend flowx_clmm::pool;

    const VERSION: u64 = 1;

    const E_WRONG_VERSION: u64 = 999;
    const E_NOT_UPGRADED: u64 = 1000;

    struct Versioned has key, store {
        id: UID,
        version: u64
    }

    public fun check_version(self: &Versioned) {
        if (self.version != VERSION) {
            abort E_WRONG_VERSION
        }
    }

    public(friend) fun check_version_and_upgrade(self: &mut Versioned) {
        if (self.version < VERSION) {
            self.version = VERSION;
        };
        check_version(self);
    }

    // public entry fun upgrade(_: &AdminCap, state: &mut State) {
    //     assert!(state.version < VERSION, ERROR_NOT_UPGRADED);
    //     state.version = VERSION;
    // }
}