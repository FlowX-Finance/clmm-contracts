module flowx_clmm::pool_manager {
    use std::type_name::{Self, TypeName};
    use sui::object::{Self, UID, ID};
    use sui::table::{Self, Table};
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin, CoinMetadata};
    use sui::dynamic_field::{Self as df};
    use sui::dynamic_object_field::{Self as dof};
    use sui::event;
    use sui::transfer;
    use sui::clock::Clock;
    use sui::vec_set::{Self, VecSet};

    use flowx_clmm::admin_cap::AdminCap;
    use flowx_clmm::pool::{Self, Pool};
    use flowx_clmm::versioned::{Self, Versioned};
    use flowx_clmm::utils;

    const E_POOL_ALREADY_CREATED: u64 = 1;
    const E_INVALID_FEE_RATE: u64 = 2;
    const E_TICK_SPACING_OVERFLOW: u64 = 3;
    const E_FEE_RATE_ALREADY_ENABLED: u64 = 4;
    const E_POOL_NOT_CREATED: u64 = 5;
    const E_FEE_RATE_NOT_ENABLED: u64 = 6;
    const E_NOT_AUTHORIZED_POOL_MANAGER: u64 = 7;

    struct PoolDfKey has copy, drop, store {
        coin_type_x: TypeName,
        coin_type_y: TypeName,
        fee_rate: u64
    }

    struct PoolManagerDfKey has copy, drop, store {}

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

    struct PoolManagerGranted has copy, drop, store {
        sender: address,
        pool_manager: address
    }

    struct PoolManagerRevoked has copy, drop, store {
        sender: address,
        pool_manager: address
    }

    fun init(ctx: &mut TxContext) {
        let pool_registry = PoolRegistry {
            id: object::new(ctx),
            fee_amount_tick_spacing: table::new(ctx),
            num_pools: 0
        };
        enable_fee_rate_internal(&mut pool_registry, 100, 2, ctx);
        enable_fee_rate_internal(&mut pool_registry, 500, 10, ctx);
        enable_fee_rate_internal(&mut pool_registry, 3000, 60, ctx);
        enable_fee_rate_internal(&mut pool_registry, 10000, 200, ctx);

        transfer::share_object(pool_registry);
    }
    
    fun pool_key<X, Y>(fee_rate: u64): PoolDfKey {
        PoolDfKey {
            coin_type_x: type_name::get<X>(),
            coin_type_y: type_name::get<Y>(),
            fee_rate
        }
    }

    /// Check if a pool exists for the given coin types and fee rate
    /// @param self The pool registry
    /// @param fee_rate The fee rate of the pool to check
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

    public fun check_pool_manager(self: &PoolRegistry, ctx: &TxContext) {
        if (
            df::exists_with_type<PoolManagerDfKey, VecSet<address>>(&self.id, PoolManagerDfKey {}) &&
            !vec_set::contains(
                df::borrow<PoolManagerDfKey, VecSet<address>>(&self.id, PoolManagerDfKey {}),
                &tx_context::sender(ctx)
            )
        ) {
            abort E_NOT_AUTHORIZED_POOL_MANAGER
        }
    }

    public fun grant_pool_manager(
        _: &AdminCap,
        self: &mut PoolRegistry,
        pool_manager: address,
        versioned: &Versioned,
        ctx: &TxContext
    ) {
        versioned::check_version(versioned);

        if (!df::exists_with_type<PoolManagerDfKey, VecSet<address>>(&self.id, PoolManagerDfKey {})) {
            df::add(&mut self.id, PoolManagerDfKey {}, vec_set::empty<address>());
        };
        
        let pool_managers = df::borrow_mut<PoolManagerDfKey, VecSet<address>>(&mut self.id, PoolManagerDfKey {});
        vec_set::insert(pool_managers, pool_manager);

        event::emit(PoolManagerGranted {
            sender: tx_context::sender(ctx),
            pool_manager
        });
    }

    public fun revoke_pool_manager(
        _: &AdminCap,
        self: &mut PoolRegistry,
        pool_manager: address,
        versioned: &Versioned,
        ctx: &TxContext
    ) {
        versioned::check_version(versioned);

        if (!df::exists_with_type<PoolManagerDfKey, VecSet<address>>(&self.id, PoolManagerDfKey {})) {
            df::add(&mut self.id, PoolManagerDfKey {}, vec_set::empty<address>());
        };
        
        let pool_managers = df::borrow_mut<PoolManagerDfKey, VecSet<address>>(&mut self.id, PoolManagerDfKey {});
        vec_set::remove(pool_managers, &pool_manager);

        event::emit(PoolManagerRevoked {
            sender: tx_context::sender(ctx),
            pool_manager
        });
    }

    /// Create a new liquidity pool for the given coin types and fee rate
    /// Only callable by pool managers.
    /// @param self The pool registry
    /// @param fee_rate The fee rate for the new pool (must be enabled)
    /// @param versioned The versioned object to check package version
    /// @param ctx The transaction context
    public fun create_pool<X, Y>(
        self: &mut PoolRegistry,
        fee_rate: u64,
        versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        versioned::check_version(versioned);
        check_pool_manager(self, ctx);
        create_pool_permission_less<X, Y>(self, fee_rate, ctx);
    }

    /// Create and immediately initialize a new liquidity pool with an initial price
    /// Only callable by pool managers.
    /// @param self The pool registry
    /// @param fee_rate The fee rate for the new pool (must be enabled)
    /// @param sqrt_price The initial square root price as a Q64.64 value
    /// @param versioned The versioned object to check package version
    /// @param clock The clock object for timing
    /// @param ctx The transaction context
    public fun create_and_initialize_pool<X, Y>(
        self: &mut PoolRegistry,
        fee_rate: u64,
        sqrt_price: u128,
        versioned: &Versioned,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        create_pool<X, Y>(self, fee_rate, versioned, ctx);
        if (utils::is_ordered<X, Y>()) {
            pool::initialize(borrow_mut_pool<X, Y>(self, fee_rate), sqrt_price, versioned, clock, ctx);
        } else {
            pool::initialize(borrow_mut_pool<Y, X>(self, fee_rate), sqrt_price, versioned, clock, ctx);
        };
    }

    /// Create a new liquidity pool for the given coin types and fee rate without checking permissions
    /// @param self The pool registry
    /// @param fee_rate The fee rate for the new pool (must be enabled)
    /// @param _metadata_x The metadata for coin X (not used)
    /// @param _metadata_y The metadata for coin Y (not used)
    /// @param versioned The versioned object to check package version
    /// @param ctx The transaction context
    public fun create_pool_v2<X, Y>(
        self: &mut PoolRegistry,
        fee_rate: u64,
        _metadata_x: &CoinMetadata<X>,
        _metadata_y: &CoinMetadata<Y>,
        versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        versioned::check_version(versioned);
        create_pool_permission_less<X, Y>(self, fee_rate, ctx);
    }

    /// Create and immediately initialize a new liquidity pool with an initial price
    /// @param self The pool registry
    /// @param fee_rate The fee rate for the new pool (must be enabled)
    /// @param sqrt_price The initial square root price as a Q64.64 value
    /// @param metadata_x The metadata for coin X
    /// @param metadata_y The metadata for coin Y
    /// @param versioned The versioned object to check package version
    /// @param clock The clock object for timing
    /// @param ctx The transaction context
    public fun create_and_initialize_pool_v2<X, Y>(
        self: &mut PoolRegistry,
        fee_rate: u64,
        sqrt_price: u128,
        metadata_x: &CoinMetadata<X>,
        metadata_y: &CoinMetadata<Y>,
        versioned: &Versioned,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        create_pool_v2<X, Y>(self, fee_rate, metadata_x, metadata_y, versioned, ctx);
        if (utils::is_ordered<X, Y>()) {
            pool::initialize(borrow_mut_pool<X, Y>(self, fee_rate), sqrt_price, versioned, clock, ctx);
        } else {
            pool::initialize(borrow_mut_pool<Y, X>(self, fee_rate), sqrt_price, versioned, clock, ctx);
        };
    }

    /// Create a new liquidity pool for the given coin types and fee rate without checking permissions
    /// @param self The pool registry
    /// @param fee_rate The fee rate for the new pool (must be enabled)
    /// @param versioned The versioned object to check package version
    /// @param ctx The transaction context
    public fun create_pool_v3<X, Y>(
        self: &mut PoolRegistry,
        fee_rate: u64,
        versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        versioned::check_version(versioned);
        create_pool_permission_less<X, Y>(self, fee_rate, ctx);
    }

    /// Create and immediately initialize a new liquidity pool with an initial price
    /// @param self The pool registry
    /// @param fee_rate The fee rate for the new pool (must be enabled)
    /// @param sqrt_price The initial square root price as a Q64.64 value
    /// @param versioned The versioned object to check package version
    /// @param clock The clock object for timing
    /// @param ctx The transaction context
    public fun create_and_initialize_pool_v3<X, Y>(
        self: &mut PoolRegistry,
        fee_rate: u64,
        sqrt_price: u128,
        versioned: &Versioned,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        create_pool_v3<X, Y>(self, fee_rate, versioned, ctx);
        if (utils::is_ordered<X, Y>()) {
            pool::initialize(borrow_mut_pool<X, Y>(self, fee_rate), sqrt_price, versioned, clock, ctx);
        } else {
            pool::initialize(borrow_mut_pool<Y, X>(self, fee_rate), sqrt_price, versioned, clock, ctx);
        };
    }

    /// Enable a new fee rate and tick spacing combination for pool creation
    /// @param admin_cap The admin capability required for this operation
    /// @param self The pool registry
    /// @param fee_rate The fee rate to enable (must be less than 1,000,000)
    /// @param tick_spacing The tick spacing for this fee rate (must be greater than 0 and less than 4,194,304)
    /// @param versioned The versioned object to check package version
    /// @param ctx The transaction context
    public fun enable_fee_rate(
        _: &AdminCap,
        self: &mut PoolRegistry,
        fee_rate: u64,
        tick_spacing: u32,
        versioned: &Versioned,
        ctx: &TxContext
    ) {
        versioned::check_version(versioned);
        if (fee_rate >= 1_000_000) {
            abort E_INVALID_FEE_RATE
        };

        if (tick_spacing == 0 || tick_spacing >= 4194304) {
            abort E_TICK_SPACING_OVERFLOW
        };

        if (table::contains(&self.fee_amount_tick_spacing, fee_rate)) {
            abort E_FEE_RATE_ALREADY_ENABLED
        };
        enable_fee_rate_internal(self, fee_rate, tick_spacing, ctx);
    }

    /// Set the protocol fee rate for a specific pool
    /// @param admin_cap The admin capability required for this operation
    /// @param self The pool registry
    /// @param fee_rate The fee rate of the pool to modify
    /// @param protocol_fee_rate_x The protocol fee rate for coin X
    /// @param protocol_fee_rate_y The protocol fee rate for coin Y
    /// @param versioned The versioned object to check package version
    /// @param ctx The transaction context
    public fun set_protocol_fee_rate<X, Y>(
        admin_cap: &AdminCap,
        self: &mut PoolRegistry,
        fee_rate: u64,
        protocol_fee_rate_x: u64,
        protocol_fee_rate_y: u64,
        versioned: &Versioned,
        ctx: &mut TxContext
    ) {
        pool::set_protocol_fee_rate(
            admin_cap, borrow_mut_pool<X, Y>(self, fee_rate), protocol_fee_rate_x, protocol_fee_rate_y, versioned, ctx
        );
    }

    /// Collect protocol fees from a specific pool
    /// @param admin_cap The admin capability required for this operation
    /// @param self The pool registry
    /// @param fee_rate The fee rate of the pool to collect from
    /// @param amount_x_requested The amount of coin X protocol fees to collect
    /// @param amount_y_requested The amount of coin Y protocol fees to collect
    /// @param versioned The versioned object to check package version
    /// @param ctx The transaction context
    /// @return Collected coin X
    /// @return Collected coin Y
    public fun collect_protocol_fee<X, Y>(
        admin_cap: &AdminCap,
        self: &mut PoolRegistry,
        fee_rate: u64,
        amount_x_requested: u64,
        amount_y_requested: u64,
        versioned: &Versioned,
        ctx: &mut TxContext
    ): (Coin<X>, Coin<Y>) {
        let (collected_x, collected_y) = pool::collect_protocol_fee(
            admin_cap, borrow_mut_pool<X, Y>(self, fee_rate), amount_x_requested, amount_y_requested, versioned, ctx
        );
        (coin::from_balance(collected_x, ctx), coin::from_balance(collected_y, ctx))
    }

    /// Initialize a pool reward for a specific pool
    /// @param admin_cap The admin capability required for this operation
    /// @param self The pool registry
    /// @param fee_rate The fee rate of the pool to initialize the reward for
    /// @param started_at_seconds The start time of the reward in seconds since epoch
    /// @param ended_at_seconds The end time of the reward in seconds since epoch
    /// @param allocated The amount of reward coins allocated to the pool
    /// @param versioned The versioned object to check package version
    /// @param clock The clock object for timing
    /// @param ctx The transaction context
    public fun initialize_pool_reward<X, Y, RewardCoinType>(
        admin_cap: &AdminCap,
        self: &mut PoolRegistry,
        fee_rate: u64,
        started_at_seconds: u64,
        ended_at_seconds: u64,
        allocated: Coin<RewardCoinType>,
        versioned: &Versioned,
        clock: &Clock,
        ctx: &TxContext
    ) {
        pool::initialize_pool_reward<X, Y, RewardCoinType>(
            admin_cap, borrow_mut_pool<X, Y>(self, fee_rate), started_at_seconds, ended_at_seconds, coin::into_balance(allocated), versioned, clock, ctx
        );
    }

    /// Increase the pool reward for a specific pool
    /// @param admin_cap The admin capability required for this operation
    /// @param self The pool registry
    /// @param fee_rate The fee rate of the pool to increase the reward for
    /// @param allocated The amount of reward coins to add to the pool
    /// @param versioned The versioned object to check package version
    /// @param clock The clock object for timing
    /// @param ctx The transaction context
    public fun increase_pool_reward<X, Y, RewardCoinType>(
        admin_cap: &AdminCap,
        self: &mut PoolRegistry,
        fee_rate: u64,
        allocated: Coin<RewardCoinType>,
        versioned: &Versioned,
        clock: &Clock,
        ctx: &TxContext
    ) {
        pool::increase_pool_reward<X, Y, RewardCoinType>(
            admin_cap, borrow_mut_pool<X, Y>(self, fee_rate), coin::into_balance(allocated), versioned, clock, ctx
        );
    }

    /// Extend the reward timestamp for a specific pool
    /// @param admin_cap The admin capability required for this operation
    /// @param self The pool registry
    /// @param fee_rate The fee rate of the pool to extend the reward for
    /// @param timestamp The new end timestamp for the reward in seconds since epoch
    /// @param versioned The versioned object to check package version
    /// @param clock The clock object for timing
    /// @param ctx The transaction context
    public fun extend_pool_reward_timestamp<X, Y, RewardCoinType>(
        admin_cap: &AdminCap,
        self: &mut PoolRegistry,
        fee_rate: u64,
        timestamp: u64,
        versioned: &Versioned,
        clock: &Clock,
        ctx: &TxContext
    ) {
        pool::extend_pool_reward_timestamp<X, Y, RewardCoinType>(
            admin_cap, borrow_mut_pool<X, Y>(self, fee_rate), timestamp, versioned, clock, ctx
        );
    }

    fun create_pool_permission_less<X, Y>(
        self: &mut PoolRegistry,
        fee_rate: u64,
        ctx: &mut TxContext
    ) {
        if (!table::contains(&self.fee_amount_tick_spacing, fee_rate)) {
            abort E_FEE_RATE_NOT_ENABLED
        };
        if (utils::is_ordered<X, Y>()) {
            create_pool_<X, Y>(self, fee_rate, ctx);
        } else {
            create_pool_<Y, X>(self, fee_rate, ctx);
        };
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

    fun enable_fee_rate_internal(
        self: &mut PoolRegistry,
        fee_rate: u64,
        tick_spacing: u32,
        ctx: &TxContext
    ) {
        table::add(&mut self.fee_amount_tick_spacing, fee_rate, tick_spacing);
        event::emit(FeeRateEnabled {
            sender: tx_context::sender(ctx),
            fee_rate,
            tick_spacing
        });
    }

    #[test_only]
    public fun create_for_testing(ctx: &mut TxContext): PoolRegistry {
        PoolRegistry {
            id: object::new(ctx),
            fee_amount_tick_spacing: table::new(ctx),
            num_pools: 0
        }
    }

    #[test_only]
    public fun destroy_for_testing(pool_registry: PoolRegistry) {
        let PoolRegistry { id, fee_amount_tick_spacing, num_pools: _} = pool_registry;
        object::delete(id);
        table::drop(fee_amount_tick_spacing);
    }

    #[test_only] 
    public fun enable_fee_rate_for_testing(
        self: &mut PoolRegistry,
        fee_rate: u64,
        tick_spacing: u32
    ) {
        table::add(&mut self.fee_amount_tick_spacing, fee_rate, tick_spacing);
    }
}

#[test_only]
module flowx_clmm::test_pool_manager {
    use sui::tx_context;
    use sui::sui::SUI;
    use sui::test_scenario;

    use flowx_clmm::i32;
    use flowx_clmm::admin_cap;
    use flowx_clmm::versioned;
    use flowx_clmm::pool_manager;
    use flowx_clmm::pool;

    struct USDC has drop {}

    struct USDT has drop {}

    #[test]
    fun test_create_pool() {
        //succeeds if fee amount is enabled
        let ctx = tx_context::dummy();
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, 100, 2);

        pool_manager::create_pool<SUI, USDC>(&mut pool_registry, 100, &versioned, &mut ctx);
        assert!(
            pool::coin_type_x(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == std::type_name::get<USDC>() &&
            pool::coin_type_y(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == std::type_name::get<SUI>() &&
            pool::sqrt_price_current(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == 0 &&
            i32::eq(pool::tick_index_current(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)), i32::zero()) &&
            pool::observation_index(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == 0 &&
            pool::observation_cardinality(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == 0 &&
            pool::observation_cardinality_next(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == 0 &&
            pool::tick_spacing(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == 2 &&
            pool::swap_fee_rate(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == 100 &&
            pool::is_locked(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)),
            0
        );

        versioned::destroy_for_testing(versioned);
        pool_manager::destroy_for_testing(pool_registry);
    }

    #[test]
    #[expected_failure(abort_code = flowx_clmm::pool_manager::E_NOT_AUTHORIZED_POOL_MANAGER)]
    public fun test_create_pool_fail_if_not_pool_manager() {
        let alice = @0xa;
        let bob = @0xb;
        let ctx = tx_context::dummy();
        let admin_cap = admin_cap::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, 100, 2);
        pool_manager::grant_pool_manager(&admin_cap, &mut pool_registry, alice, &versioned, &ctx);

        let scenario = test_scenario::begin(alice);

        test_scenario::next_tx(&mut scenario, alice);
        {
            pool_manager::create_pool<SUI, USDC>(&mut pool_registry, 100, &versioned, test_scenario::ctx(&mut scenario));
        };

        test_scenario::next_tx(&mut scenario, bob);
        {
            pool_manager::create_pool<SUI, USDT>(&mut pool_registry, 100, &versioned, test_scenario::ctx(&mut scenario));
        };

        test_scenario::end(scenario);

        admin_cap::destroy_for_testing(admin_cap);
        versioned::destroy_for_testing(versioned);
        pool_manager::destroy_for_testing(pool_registry);

        abort 999
    }

    #[test]
    fun test_create_and_initialize_pool() {
        use sui::clock;
        //succeeds if fee amount is enabled
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, 100, 2);

        pool_manager::create_and_initialize_pool<SUI, USDC>(
            &mut pool_registry, 100, 1844674407370955161, &versioned, &clock, &mut ctx
        );
        assert!(
            pool::coin_type_x(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == std::type_name::get<USDC>() &&
            pool::coin_type_y(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == std::type_name::get<SUI>() &&
            pool::sqrt_price_current(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == 1844674407370955161 &&
            i32::eq(pool::tick_index_current(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)), i32::neg_from(46055)) &&
            pool::observation_index(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == 0 &&
            pool::observation_cardinality(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == 1 &&
            pool::observation_cardinality_next(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == 1 &&
            pool::tick_spacing(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == 2 &&
            pool::swap_fee_rate(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)) == 100 &&
            !pool::is_locked(pool_manager::borrow_pool<USDC, SUI>(&pool_registry, 100)),
            0
        );

        clock::destroy_for_testing(clock);
        versioned::destroy_for_testing(versioned);
        pool_manager::destroy_for_testing(pool_registry);
    }

    #[test]
    #[expected_failure(abort_code = flowx_clmm::pool_manager::E_FEE_RATE_NOT_ENABLED)]
    fun test_create_pool_fail_if_fee_amount_is_not_enabled() {
        //fails if fee amount is not enabled
        let ctx = tx_context::dummy();
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);

        pool_manager::create_pool<SUI, USDC>(&mut pool_registry, 100, &versioned, &mut ctx);

        versioned::destroy_for_testing(versioned);
        pool_manager::destroy_for_testing(pool_registry);
    }

    #[test]
    #[expected_failure(abort_code = flowx_clmm::utils::E_IDENTICAL_COIN)]
    fun test_create_pool_fail_if_x_and_y_are_identical() {
        //fails if x and y are indentical
        let ctx = tx_context::dummy();
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, 100, 2);

        pool_manager::create_pool<SUI, SUI>(&mut pool_registry, 100, &versioned, &mut ctx);

        versioned::destroy_for_testing(versioned);
        pool_manager::destroy_for_testing(pool_registry);
    }

    #[test]
    fun test_create_and_initialize_pool_v3() {
        use sui::clock;
        //succeeds if fee amount is enabled
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let pool_registry = pool_manager::create_for_testing(&mut ctx);
        pool_manager::enable_fee_rate_for_testing(&mut pool_registry, 100, 2);

        pool_manager::create_and_initialize_pool_v3<SUI, USDC>(
            &mut pool_registry,
            100,
            1844674407370955161,
            &versioned,
            &clock,
            &mut ctx,
        );

        assert!(
            pool::coin_type_x(pool_manager::borrow_pool<SUI, USDC>(&pool_registry, 100)) == std::type_name::get<SUI>() &&
            pool::coin_type_y(pool_manager::borrow_pool<SUI, USDC>(&pool_registry, 100)) == std::type_name::get<USDC>() &&
            pool::sqrt_price_current(pool_manager::borrow_pool<SUI, USDC>(&pool_registry, 100)) == 1844674407370955161 &&
            i32::eq(pool::tick_index_current(pool_manager::borrow_pool<SUI, USDC>(&pool_registry, 100)), i32::neg_from(46055)) &&
            pool::observation_index(pool_manager::borrow_pool<SUI, USDC>(&pool_registry, 100)) == 0 &&
            pool::observation_cardinality(pool_manager::borrow_pool<SUI, USDC>(&pool_registry, 100)) == 1 &&
            pool::observation_cardinality_next(pool_manager::borrow_pool<SUI, USDC>(&pool_registry, 100)) == 1 &&
            pool::tick_spacing(pool_manager::borrow_pool<SUI, USDC>(&pool_registry, 100)) == 2 &&
            pool::swap_fee_rate(pool_manager::borrow_pool<SUI, USDC>(&pool_registry, 100)) == 100 &&
            !pool::is_locked(pool_manager::borrow_pool<SUI, USDC>(&pool_registry, 100)),
            0,
        );

        clock::destroy_for_testing(clock);
        versioned::destroy_for_testing(versioned);
        pool_manager::destroy_for_testing(pool_registry);
    }
}