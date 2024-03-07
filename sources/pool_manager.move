module flowx_clmm::pool_manager {
    use std::type_name::{Self, TypeName};
    use sui::object::{Self, UID, ID};
    use sui::table::{Self, Table};
    use sui::tx_context::{Self, TxContext};
    use sui::dynamic_object_field::{Self as dof};
    use sui::event;
    use sui::transfer;
    use sui::clock::Clock;

    use flowx_clmm::admin_cap::AdminCap;
    use flowx_clmm::pool::{Self, Pool};
    use flowx_clmm::versioned::{Self, Versioned};
    use flowx_clmm::utils;

    const E_POOL_ALREADY_CREATED: u64 = 1;
    const E_INVALID_FEE_RATE: u64 = 2;
    const E_TICK_SPACING_OVERFLOW: u64 = 3;
    const E_FEE_RATE_ALREADY_ENABLED: u64 = 4;
    const E_POOL_NOT_CREATED: u64 = 5;

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

    struct PoolCreated has copy, drop, store {
        sender: address,
        pool_id: ID,
        coin_type_x: TypeName,
        coin_type_y: TypeName,
        fee_rate: u64,
        tick_spacing: u32
    }

    struct FeeRateEnabled has copy, drop, store {
        sender: address,
        fee_rate: u64,
        tick_spacing: u32
    }

    fun init(ctx: &mut TxContext) {
        transfer::share_object(PoolRegistry {
            id: object::new(ctx),
            fee_amount_tick_spacing: table::new(ctx),
            num_pools: 0
        });
    }
    
    fun pool_key<X, Y>(fee_rate: u64): PoolDfKey {
        PoolDfKey {
            coin_type_x: type_name::get<X>(),
            coin_type_y: type_name::get<Y>(),
            fee_rate
        }
    }

    public fun check_exists<X, Y>(self: &PoolRegistry, fee_rate: u64) {
        if (!dof::exists_(&self.id, pool_key<X, Y>(fee_rate))) {
            abort E_POOL_NOT_CREATED
        };
    }

    public fun borrow_pool<X, Y>(self: &PoolRegistry, fee_rate: u64): &Pool<X, Y> {
        check_exists<X, Y>(self, fee_rate);
        dof::borrow<PoolDfKey, Pool<X, Y>>(&self.id, pool_key<X, Y>(fee_rate))
    }

    public fun borrow_mut_pool<X, Y>(self: &mut PoolRegistry, fee_rate: u64): &mut Pool<X, Y> {
        check_exists<X, Y>(self, fee_rate);
        dof::borrow_mut<PoolDfKey, Pool<X, Y>>(&mut self.id, pool_key<X, Y>(fee_rate))
    }

    fun create_pool_<X, Y>(
        self: &mut PoolRegistry,
        fee_rate: u64,
        ctx: &mut TxContext
    ) {
        let tick_spacing = *table::borrow(&self.fee_amount_tick_spacing, fee_rate);
        let key = pool_key<X, Y>(fee_rate);
        if (dof::exists_(&self.id, key)) {
            abort E_POOL_ALREADY_CREATED
        };
        let pool = pool::create<X, Y>(fee_rate, tick_spacing, ctx);
        event::emit(PoolCreated {
            sender: tx_context::sender(ctx),
            pool_id: object::id(&pool),
            coin_type_x: pool::coin_type_x(&pool),
            coin_type_y: pool::coin_type_y(&pool),
            fee_rate,
            tick_spacing
        });
        dof::add(&mut self.id, key, pool);
        self.num_pools = self.num_pools + 1;
    }

    public fun create_pool<X, Y>(
        self: &mut PoolRegistry,
        fee_rate: u64,
        versioned: &mut Versioned,
        ctx: &mut TxContext
    ) {
        versioned::check_version_and_upgrade(versioned);
        if (utils::is_ordered<X, Y>()) {
            create_pool_<X, Y>(self, fee_rate, ctx);
        } else {
            create_pool_<Y, X>(self, fee_rate, ctx);
        };
    }

    public fun create_and_initialize_pool<X, Y>(
        self: &mut PoolRegistry,
        fee_rate: u64,
        sqrt_price: u128,
        versioned: &mut Versioned,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        create_pool<X, Y>(self, fee_rate, versioned, ctx);
        if (utils::is_ordered<X, Y>()) {
            pool::initialize(borrow_mut_pool<X, Y>(self, fee_rate), sqrt_price, clock);
        } else {
            pool::initialize(borrow_mut_pool<Y, X>(self, fee_rate), sqrt_price, clock);
        };
    }

    public fun enable_fee_rate(
        _: &AdminCap,
        self: &mut PoolRegistry,
        fee_rate: u64,
        tick_spacing: u32,
        versioned: &mut Versioned,
        ctx: &TxContext
    ) {
        versioned::check_version_and_upgrade(versioned);
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
            sender: tx_context::sender(ctx),
            fee_rate,
            tick_spacing
        });
    }
}