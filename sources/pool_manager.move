module flowx_clmm::pool_manager {
    use std::type_name::{Self, TypeName};
    use std::ascii;
    use sui::object::{Self, UID};
    use sui::table::{Self, Table};
    use sui::tx_context::{Self, TxContext};
    use sui::dynamic_object_field::{Self as dof};
    use sui::transfer;
    use sui::event;

    use flowx_clmm::admin_cap::AdminCap;
    use flowx_clmm::comparator;
    use flowx_clmm::pool;
    use flowx_clmm::versioned::{Self, Versioned};

    const E_IDENTICAL_COIN: u64 = 0;
    const E_POOL_ALREADY_CREATED: u64 = 1;
    const E_INVALID_FEE_RATE: u64 = 2;
    const E_TICK_SPACING_OVERFLOW: u64 = 3;
    const E_FEE_RATE_ALREADY_ENABLED: u64 = 4;

    struct PoolDfKey has copy, drop, store {
        coin_type_x: TypeName,
        coin_type_y: TypeName,
        fee_rate: u64
    }

    struct PoolRegistry has key, store {
        id: UID,
        fee_amount_tick_spacing: Table<u64, u32>,
        num_pools: u64
    }

    struct FeeRateEnabled has copy, drop, store {
        fee_rate: u64,
        tick_spacing: u32
    }

    public fun is_ordered<X, Y>(): bool {
        let x_name = type_name::into_string(type_name::get<X>());
        let y_name = type_name::into_string(type_name::get<Y>());

        let result = comparator::compare_u8_vector(ascii::into_bytes(x_name), ascii::into_bytes(y_name));
        assert!(!comparator::is_equal(&result), E_IDENTICAL_COIN);
        
        comparator::is_smaller_than(&result)
    }

    public fun create_pool<X, Y>(
        self: &mut PoolRegistry,
        fee_rate: u64,
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ) {
        versioned::check_version_and_upgrade(versioned);
        let tick_spacing = *table::borrow(&self.fee_amount_tick_spacing, fee_rate);
        if (is_ordered<X, Y>()) {
            let key = PoolDfKey {
                coin_type_x: type_name::get<X>(),
                coin_type_y: type_name::get<Y>(),
                fee_rate
            };
            if (dof::exists_(&self.id, key)) {
                abort E_POOL_ALREADY_CREATED
            };
            let pool = pool::create<X, Y>(fee_rate, tick_spacing, ctx);
            dof::add(&mut self.id, key, pool);
        } else {
            let key = PoolDfKey {
                coin_type_x: type_name::get<Y>(),
                coin_type_y: type_name::get<X>(),
                fee_rate
            };
            if (dof::exists_(&self.id, key)) {
                abort E_POOL_ALREADY_CREATED
            };
            let pool = pool::create<Y, X>(fee_rate, tick_spacing, ctx);
            dof::add(&mut self.id, key, pool);
        };
        self.num_pools = self.num_pools + 1;
    }

    public fun enable_fee_rate(
        _: &AdminCap,
        self: &mut PoolRegistry,
        fee_rate: u64,
        tick_spacing: u32
    ) {
        if (fee_rate >= 1_000_000) {
            abort E_INVALID_FEE_RATE
        };

        if (tick_spacing >= 4194304) {
            abort E_TICK_SPACING_OVERFLOW
        };

        if (table::contains(&self.fee_amount_tick_spacing, fee_rate)) {
            abort E_FEE_RATE_ALREADY_ENABLED
        };

        table::add(&mut self.fee_amount_tick_spacing, fee_rate, tick_spacing);
        event::emit(FeeRateEnabled {
            fee_rate,
            tick_spacing
        });
    }
}