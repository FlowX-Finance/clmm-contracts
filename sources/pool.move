module flowx_clmm::pool {
    use std::type_name::{Self, TypeName};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use sui::dynamic_field::{Self as df};
    use sui::event;
    use sui::clock::{Self, Clock};
    
    use flowx_clmm::admin_cap::AdminCap;
    use flowx_clmm::i32::{Self, I32};
    use flowx_clmm::i128::{Self, I128};
    use flowx_clmm::tick::{Self, TickInfo};
    use flowx_clmm::position::{Self, Position};
    use flowx_clmm::versioned::{Self, Versioned};
    use flowx_clmm::liquidity_math;
    use flowx_clmm::tick_bitmap;
    use flowx_clmm::tick_math;
    use flowx_clmm::sqrt_price_math;
    use flowx_clmm::swap_math;
    use flowx_clmm::constants;
    use flowx_clmm::full_math_u64;
    use flowx_clmm::full_math_u128;
    use flowx_clmm::oracle::{Self, Observation};
    use flowx_clmm::utils;

    friend flowx_clmm::pool_manager;

    const E_POOL_ID_MISMATCH: u64 = 0;
    const E_INSUFFICIENT_INPUT_AMOUNT: u64 = 1;
    const E_POOL_ALREADY_INITIALIZED: u64 = 2;
    const E_POOL_ALREADY_LOCKED: u64 = 3;
    const E_PRICE_LIMIT_ALREADY_EXCEEDED: u64 = 4;
    const E_PRICE_LIMIT_OUT_OF_BOUNDS: u64 = 5;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 6;
    const E_INVALID_PROTOCOL_FEE_RATE: u64 = 7;

    struct ReserveDfKey<phantom T> has copy, drop, store {}

    struct Pool<phantom CoinX, phantom CoinY> has key, store {
        id: UID,
        coin_type_x: TypeName,
        coin_type_y: TypeName,
        // the current price
        sqrt_price: u128,
        // the current tick
        tick_index: I32,
        observation_index: u64,
        observation_cardinality: u64,
        observation_cardinality_next: u64,
        // the pool tick spacing
        tick_spacing: u32,
        max_liquidity_per_tick: u128,
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        protocol_fee_rate: u64,
        // used for the swap fee, either static at initialize or dynamic via hook
        swap_fee_rate: u64,
        fee_growth_global_x: u128,
        fee_growth_global_y: u128,
        protocol_fee_x: u64,
        protocol_fee_y: u64,
        // the currently in range liquidity available to the pool
        liquidity: u128,
        ticks: Table<I32, TickInfo>,
        tick_bitmap: Table<I32, u256>,
        observations: vector<Observation>,
        locked: bool
    }

    struct SwapState has copy, drop {
        amount_specified_remaining: u64,
        amount_calculated: u64,
        sqrt_price: u128,
        tick_index: I32,
        fee_growth_global: u128,
        protocol_fee: u64,
        liquidity: u128
    }

    struct SwapStepComputations has copy, drop {
        sqrt_price_start: u128,
        tick_index_next: I32,
        initialized: bool,
        sqrt_price_next: u128,
        amount_in: u64,
        amount_out: u64,
        fee_amount: u64
    }

    struct Receipt {
        pool_id: ID,
        amount_x_debt: u64,
        amount_y_debt: u64
    }

    struct ModifyLiquidity has copy, drop, store {
        sender: address,
        pool_id: ID,
        position_id: ID,
        tick_lower_index: I32,
        tick_upper_index: I32,
        liquidity_delta: I128,
        amount_x: u64,
        amount_y: u64
    }

    struct Swap has copy, drop, store {
        sender: address,
        pool_id: ID,
        amount_x: u64,
        amount_y: u64,
        sqrt_price: u128,
        liquidity: u128,
        tick_index: I32
    }

    struct Flash has copy, drop, store {
        sender: address,
        pool_id: ID,
        amount_x: u64,
        amount_y: u64
    }

    struct Collect has copy, drop, store {
        sender: address,
        pool_id: ID,
        position_id: ID,
        amount_x: u64,
        amount_y: u64
    }

    struct CollectProtocolFee has copy, drop, store {
        sender: address,
        pool_id: ID,
        amount_x: u64,
        amount_y: u64
    }
    
    struct SetProtocolFeeRate has copy, drop, store {
        sender: address,
        pool_id: ID,
        protocol_fee_rate_x_old: u64,
        protocol_fee_rate_y_old: u64,
        protocol_fee_rate_x_new: u64,
        protocol_fee_rate_y_new: u64
    }

    struct Initialize has copy, drop, store {
        pool_id: ID,
        sqrt_price: u128,
        tick_index: I32
    }

    public fun sqrt_price_current<X, Y>(self: &Pool<X, Y>): u128 { self.sqrt_price }

    public fun tick_index_current<X, Y>(self: &Pool<X, Y>): I32 { self.tick_index }

    public fun coin_type_x<X, Y>(self: &Pool<X, Y>): TypeName { self.coin_type_x }

    public fun coin_type_y<X, Y>(self: &Pool<X, Y>): TypeName { self.coin_type_y }

    public fun reserves<X, Y>(self: &Pool<X, Y>): (u64, u64) {
        (
            balance::value(df::borrow<ReserveDfKey<X>, Balance<X>>(&self.id, ReserveDfKey<X> {})),
            balance::value(df::borrow<ReserveDfKey<Y>, Balance<Y>>(&self.id, ReserveDfKey<Y> {}))
        )
    }

    public fun swap_fee_rate<X, Y>(self: &Pool<X, Y>): u64 { self.swap_fee_rate }

    public fun receipt_debts(receipt: &Receipt): (u64, u64) { (receipt.amount_x_debt, receipt.amount_y_debt) }

    public(friend) fun create<X, Y>(
        fee_rate: u64,
        tick_spacing: u32,
        ctx: &mut TxContext
    ): Pool<X, Y> {
        let pool = Pool<X, Y> {
            id: object::new(ctx),
            coin_type_x: type_name::get<X>(),
            coin_type_y: type_name::get<Y>(),
            sqrt_price: 0,
            tick_index: i32::zero(),
            tick_spacing,
            max_liquidity_per_tick: tick::tick_spacing_to_max_liquidity_per_tick(tick_spacing),
            protocol_fee_rate: 0,
            swap_fee_rate: fee_rate,
            fee_growth_global_x: 0,
            fee_growth_global_y: 0,
            protocol_fee_x: 0,
            protocol_fee_y: 0,
            liquidity: 0,
            ticks: table::new(ctx),
            tick_bitmap: table::new(ctx),
            observation: vector::empty(),
            locked: true
        };
        df::add(&mut pool.id, ReserveDfKey<X> {}, balance::zero<X>());
        df::add(&mut pool.id, ReserveDfKey<Y> {}, balance::zero<Y>());
        pool
    }

    public fun initialize<X, Y>(
        self: &mut Pool<X, Y>,
        sqrt_price: u128,
        clock: &Clock
    ) {
        if (self.sqrt_price > 0) {
            abort E_POOL_ALREADY_INITIALIZED
        };

        let tick_index = tick_math::get_tick_at_sqrt_price(sqrt_price);
        self.tick_index = tick_index;
        self.sqrt_price = sqrt_price;

        let (cardinality, cardinality_next) = oracle::initialize(clock::timestamp_ms(&clock));
        self.observation_cardinality = cardinality;
        self.cardinality_next = cardinality_next;
        self.locked = false;

        event::emit(Initialize {
            pool_id: object::id(self),
            sqrt_price,
            tick_index
        });
    }

    public fun modify_liquidity<X, Y>(
        self: &mut Pool<X, Y>,
        position: &mut Position,
        liquidity_delta: I128,
        x_in: Balance<X>,
        y_in: Balance<Y>,
        versioned: &mut Versioned,
        clock: &Clock,
        ctx: &TxContext
    ): (u64, u64) {
        versioned::check_version_and_upgrade(versioned);
        check_lock(self);
        check_pool_match(self, position::pool_id(position));

        self.locked = true;
        let add = i128::gte(liquidity_delta, i128::zero());
        let (amount_x, amount_y) = modify_position(self, position, liquidity_delta, clock);

        if (add) {
            if (balance::value(&x_in) < amount_x || balance::value(&y_in) < amount_y) {
                abort E_INSUFFICIENT_INPUT_AMOUNT
            };
        } else {
            if (amount_x > 0 || amount_y > 0) {
                position::increase_debt(position, amount_x, amount_y);
            };
        };

        put(self, x_in, y_in);
        self.locked = false;

        event::emit(ModifyLiquidity{
            sender: tx_context::sender(ctx),
            pool_id: object::id(self),
            position_id: object::id(position),
            tick_lower_index: position::tick_lower_index(position),
            tick_upper_index: position::tick_upper_index(position),
            liquidity_delta,
            amount_x,
            amount_y
        });

        (amount_x, amount_y)
    }

    public fun swap<X, Y>(
        self: &mut Pool<X, Y>,
        x_for_y: bool,
        exact_in: bool,
        amount_specified: u64,
        sqrt_price_limit: u128,
        versioned: &mut Versioned,
        ctx: &TxContext
    ): (Balance<X>, Balance<Y>, Receipt) {
        versioned::check_version_and_upgrade(versioned);
        check_lock(self);
        
        if (x_for_y) {
            if (sqrt_price_limit >= self.sqrt_price) {
                abort E_PRICE_LIMIT_ALREADY_EXCEEDED
            } else if (sqrt_price_limit <= tick_math::min_sqrt_price()) {
                abort E_PRICE_LIMIT_OUT_OF_BOUNDS
            };
        } else {
            if (sqrt_price_limit <= self.sqrt_price) {
                abort E_PRICE_LIMIT_ALREADY_EXCEEDED
            } else if (sqrt_price_limit >= tick_math::max_sqrt_price()) {
                abort E_PRICE_LIMIT_OUT_OF_BOUNDS
            }
        };

        self.locked = true;
        let protocol_fee_rate = if (exact_in) {
            self.protocol_fee_rate % 16
        } else {
            self.protocol_fee_rate >> 4
        };

        let fee_growth_global = if (x_for_y) {
            self.fee_growth_global_x
        } else {
            self.fee_growth_global_y
        };
        let state = SwapState {
            amount_specified_remaining: amount_specified,
            amount_calculated: 0,
            sqrt_price: self.sqrt_price,
            tick_index: self.tick_index,
            fee_growth_global,
            protocol_fee: 0,
            liquidity: self.liquidity
        };

        while(state.amount_specified_remaining != 0 && state.sqrt_price != sqrt_price_limit) {
            let step = SwapStepComputations {
                sqrt_price_start: 0,
                tick_index_next: i32::zero(),
                initialized: false,
                sqrt_price_next: 0,
                amount_in: 0,
                amount_out: 0,
                fee_amount: 0
            };

            step.sqrt_price_start = state.sqrt_price;
            let (next, initialized) = tick_bitmap::next_initialized_tick_within_one_word(
                &self.tick_bitmap,
                state.tick_index,
                self.tick_spacing,
                x_for_y
            );
            step.tick_index_next = next;
            step.initialized = initialized;

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (i32::lt(step.tick_index_next, tick_math::min_tick())) {
                step.tick_index_next = tick_math::min_tick();
            } else if (i32::gt(step.tick_index_next, tick_math::max_tick())){
                step.tick_index_next = tick_math::max_tick();
            };

            // get the price for the next tick
            step.sqrt_price_next = tick_math::get_sqrt_price_at_tick(step.tick_index_next);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            let sqrt_price_target = if (x_for_y) {
                full_math_u128::max(step.sqrt_price_next, sqrt_price_limit)
            } else {
                full_math_u128::min(step.sqrt_price_next, sqrt_price_limit)
            };
    
            let (sqrt_price, amount_in, amount_out, fee_amount) = swap_math::compute_swap_step(
                state.sqrt_price,
                sqrt_price_target,
                state.liquidity,
                state.amount_specified_remaining,
                self.swap_fee_rate,
                exact_in
            );
            state.sqrt_price = sqrt_price;
            step.amount_in = amount_in;
            step.amount_out = amount_out;
            step.fee_amount = fee_amount;

            if (exact_in) {
                state.amount_specified_remaining = state.amount_specified_remaining - (step.amount_in + step.fee_amount);
                state.amount_calculated = state.amount_calculated + step.amount_out;
            } else {
                state.amount_specified_remaining = state.amount_specified_remaining - step.amount_out;
                state.amount_calculated = state.amount_calculated + (step.amount_in + step.fee_amount);
            };

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            if (protocol_fee_rate > 0) {
                let delta = step.fee_amount / protocol_fee_rate;
                step.fee_amount = step.fee_amount - delta;
                state.protocol_fee = state.protocol_fee + delta;
            };

            // update global fee tracker
            if (state.liquidity > 0) {
                state.fee_growth_global = state.fee_growth_global + full_math_u128::mul_div_floor(
                    (step.fee_amount as u128),
                    (constants::get_q64() as u128),
                    state.liquidity
                );
            };

            // shift tick if we reached the next price
            if (state.sqrt_price == step.sqrt_price_next) {
                // if the tick is initialized, run the tick transition
                let (fee_growth_global_x, fee_growth_global_y) = if (x_for_y) {
                    (state.fee_growth_global, self.fee_growth_global_y)
                } else {
                    (self.fee_growth_global_x, state.fee_growth_global)
                };

                if (step.initialized) {
                    // check for the placeholder value, which we replace with the actual value the first time the swap
                    // crosses an initialized tick
                    let liquidity_net = tick::cross(
                        &mut self.ticks,
                        step.tick_index_next,
                        fee_growth_global_x,
                        fee_growth_global_y
                    );

                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    if (x_for_y) {
                        liquidity_net = i128::neg(liquidity_net);
                    };

                    state.liquidity = liquidity_math::add_delta(state.liquidity, liquidity_net);
                };

                state.tick_index = if (x_for_y) {
                    i32::sub(step.tick_index_next, i32::from(1))
                } else {
                    step.tick_index_next
                };
            } else if (state.sqrt_price != step.sqrt_price_start) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick_index = tick_math::get_tick_at_sqrt_price(state.sqrt_price);
            }
        };

        // update tick and write an oracle entry if the tick change
        if (!i32::eq(state.tick_index, self.tick_index)) {
            self.sqrt_price = state.sqrt_price;
            self.tick_index = state.tick_index;
        } else {
            // otherwise just update the price
            self.sqrt_price = state.sqrt_price;
        };

        // update liquidity if it changed
        if (self.liquidity != state.liquidity) {
            self.liquidity = state.liquidity;
        };

        // update fee growth global and, if necessary, protocol fees
        if (x_for_y) {
            self.fee_growth_global_x = state.fee_growth_global;
            self.protocol_fee_x = self.protocol_fee_x + state.protocol_fee;
        } else {
            self.fee_growth_global_y = state.fee_growth_global;
            self.protocol_fee_y = self.protocol_fee_y + state.protocol_fee;
        };

        let (amount_x, amount_y) = if (x_for_y == exact_in) {
            (amount_specified - state.amount_specified_remaining, state.amount_calculated)
        } else {
            (state.amount_calculated, amount_specified - state.amount_specified_remaining)
        };

        let (x_out, y_out) = if (x_for_y) {
            take(self, 0, amount_y)
        } else {
            take(self, amount_x, 0)
        };

        event::emit(Swap {
            pool_id: object::id(self),
            sender: tx_context::sender(ctx),
            amount_x,
            amount_y,
            sqrt_price: state.sqrt_price,
            liquidity: state.liquidity,
            tick_index: state.tick_index
        });

        (x_out, y_out, Receipt {
            pool_id: object::id(self),
            amount_x_debt: amount_x,
            amount_y_debt: amount_y
        })
    }

    public fun pay<X, Y>(
        self: &mut Pool<X, Y>,
        receipt: Receipt,
        payment_x: Balance<X>,
        payment_y: Balance<Y>,
        versioned: &mut Versioned
    ) {
        versioned::check_version_and_upgrade(versioned);
        check_pool_match(self, receipt.pool_id);

        let Receipt { pool_id: _, amount_x_debt, amount_y_debt } = receipt;
        let (balance_x_before, balance_y_before) = reserves(self);
        put(self, payment_x, payment_y);
        let (balance_x_after, balance_y_after) = reserves(self);

        if (
            (balance_x_before + amount_x_debt > balance_x_after) ||
            (balance_y_before + amount_y_debt > balance_y_after)
        ) {
            abort E_INSUFFICIENT_INPUT_AMOUNT
        };        
        self.locked = false;
    }

    public fun flash<X, Y>(
        self: &mut Pool<X, Y>,
        amount_x: u64,
        amount_y: u64,
        versioned: &mut Versioned,
        ctx: &TxContext
    ): (Balance<X>, Balance<Y>, Receipt) {
        versioned::check_version_and_upgrade(versioned);
        check_lock(self);

        self.locked = true;
        if (self.liquidity == 0) {
            abort E_INSUFFICIENT_LIQUIDITY
        };

        let (fee_amount_x, fee_amount_y) = (
            full_math_u64::mul_div_floor(
                amount_x,
                self.swap_fee_rate,
                constants::get_fee_rate_denominator_value()
            ),
            full_math_u64::mul_div_floor(
                amount_y,
                self.swap_fee_rate,
                constants::get_fee_rate_denominator_value()
            )
        );

        let (x_flashed, y_flashed) = take(self, amount_x, amount_y);

        event::emit(Flash {
            sender: tx_context::sender(ctx),
            pool_id: object::id(self),
            amount_x,
            amount_y
        });

        (
            x_flashed,
            y_flashed,
            Receipt {
                pool_id: object::id(self),
                amount_x_debt: amount_x + fee_amount_x,
                amount_y_debt: amount_y + fee_amount_y
            }
        )
    }

    public fun repay<X, Y>(
        self: &mut Pool<X, Y>,
        receipt: Receipt,
        payment_x: Balance<X>,
        payment_y: Balance<Y>
    ) {
        check_pool_match(self, receipt.pool_id);
        
        let Receipt { pool_id: _, amount_x_debt, amount_y_debt } = receipt;
        let (balance_x_before, balance_y_before) = reserves(self);
        put(self, payment_x, payment_y);
        let (balance_x_after, balance_y_after) = reserves(self);

        if (
            (balance_x_before + amount_x_debt > balance_x_after) ||
            (balance_y_before + amount_y_debt > balance_y_after)
        ) {
            abort E_INSUFFICIENT_INPUT_AMOUNT
        };

        // sub is safe because we know balanceAfter is gt balanceBefore by at least fee
        let paid_x = balance_y_after - balance_x_before;
        let paid_y = balance_y_after - balance_y_before;

        if (paid_x > 0) {
            let protocol_fee_rate_x = self.protocol_fee_rate % 16;
            let fee_x = if (protocol_fee_rate_x == 0) {
                0
            } else {
                paid_x / protocol_fee_rate_x
            };
            self.protocol_fee_x = self.protocol_fee_x + fee_x;
            self.fee_growth_global_x = 
                self.fee_growth_global_x + full_math_u128::mul_div_floor(((paid_x - fee_x) as u128), (constants::get_q64() as u128), self.liquidity);
        } else {
            let protocol_fee_rate_y = self.protocol_fee_rate >> 16;
            let fee_y = if (protocol_fee_rate_y == 0) {
                0
            } else {
                paid_y / protocol_fee_rate_y
            };
            self.protocol_fee_y = self.protocol_fee_y + fee_y;
            self.fee_growth_global_y =
                self.fee_growth_global_y + full_math_u128::mul_div_floor(((paid_y - fee_y) as u128), (constants::get_q64() as u128), self.liquidity);
        };
        self.locked = false;
    }

    public fun collect<X, Y>(
        self: &mut Pool<X, Y>,
        position: &mut Position,
        amount_x_requested: u64,
        amount_y_requested: u64,
        versioned: &mut Versioned,
        ctx: &TxContext
    ): (Balance<X>, Balance<Y>) {
        versioned::check_version_and_upgrade(versioned);
        check_lock(self);
        check_pool_match(self, position::pool_id(position));

        self.locked = true;
        let amount_x = if (amount_x_requested > position::coins_owed_x(position)) {
            position::coins_owed_x(position)
        } else {
            amount_x_requested
        };
        let amount_y = if (amount_y_requested > position::coins_owed_y(position)) {
            position::coins_owed_y(position)
        } else {
            amount_y_requested
        };

        position::decrease_debt(position, amount_x, amount_y);
        self.locked = false;

        event::emit(Collect {
            sender: tx_context::sender(ctx),
            pool_id: object::id(self),
            position_id: object::id(position),
            amount_x,
            amount_y
        });

        take(self, amount_x, amount_y)
    }

    public fun collect_protocol_fee<X, Y>(
        _: &AdminCap,
        self: &mut Pool<X, Y>,
        amount_x_requested: u64,
        amount_y_requested: u64,
        versioned: &mut Versioned,
        ctx: &TxContext
    ): (Balance<X>, Balance<Y>) {
        versioned::check_version_and_upgrade(versioned);
        check_lock(self);

        self.locked = true;
         let amount_x = if (amount_x_requested > self.protocol_fee_x) {
            self.protocol_fee_x
        } else {
            amount_x_requested
        };
        let amount_y = if (amount_y_requested > self.protocol_fee_y) {
            self.protocol_fee_y
        } else {
            amount_y_requested
        };
        self.protocol_fee_x = self.protocol_fee_x - amount_x;
        self.protocol_fee_y = self.protocol_fee_y - amount_y;
        self.locked = false;

        event::emit(CollectProtocolFee {
            sender: tx_context::sender(ctx),
            pool_id: object::id(self),
            amount_x,
            amount_y
        });

        take(self, amount_x, amount_y)
    }

    public fun set_protocol_fee_rate<X, Y>(
        self: &mut Pool<X, Y>,
        protocol_fee_rate_x: u64,
        protocol_fee_rate_y: u64,
        versioned: &mut Versioned,
        ctx: &TxContext
    ) {
        versioned::check_version_and_upgrade(versioned);
        check_lock(self);

        self.locked = true;
        if (
            (protocol_fee_rate_x != 0 && (protocol_fee_rate_x > 4 || protocol_fee_rate_x > 10)) ||
            (protocol_fee_rate_y != 0 && (protocol_fee_rate_y > 4 || protocol_fee_rate_y > 10))
        ) {
            abort E_INVALID_PROTOCOL_FEE_RATE
        };
        self.protocol_fee_rate = protocol_fee_rate_x + (protocol_fee_rate_y << 4);
        self.locked = false;

        event::emit(SetProtocolFeeRate {
            sender: tx_context::sender(ctx),
            pool_id: object::id(self),
            protocol_fee_rate_x_old: self.protocol_fee_rate % 16,
            protocol_fee_rate_y_old: self.protocol_fee_rate >> 4,
            protocol_fee_rate_x_new: protocol_fee_rate_x,
            protocol_fee_rate_y_new: protocol_fee_rate_y,
        });
    }

    fun modify_position<X, Y>(
        pool: &mut Pool<X, Y>,
        position: &mut Position,
        liquidity_delta: I128,
        clock: &Clock,
    ): (u64, u64) {
        let add = i128::gte(liquidity_delta, i128::zero());
        let (tick_lower_index, tick_upper_index) = (position::tick_lower_index(position), position::tick_upper_index(position));
        let liquidity_delta_abs = i128::abs_u128(liquidity_delta);

        update_position(pool, position, liquidity_delta);

        if (!i128::eq(liquidity_delta, i128::zero())) {
            let (amount_x, amount_y) = if (i32::lt(pool.tick_index, tick_lower_index)) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to right
                (
                    sqrt_price_math::get_amount_x_delta(
                        tick_math::get_sqrt_price_at_tick(tick_lower_index),
                        tick_math::get_sqrt_price_at_tick(tick_upper_index),
                        liquidity_delta_abs,
                        add
                    ),
                    0
                )
            } else if (i32::lt(pool.tick_index, tick_upper_index)) {
                // current tick is inside the passed range
                let (observation_index, observation_cardinality) = oracle::write(
                    &pool.observations,
                    pool.observation_index,
                    utils::to_seconds(clock::timestamp_ms(clock)),
                    pool.tick_index,
                    pool.liquidity,
                    pool.observation_cardinality,
                    pool.observation_cardinality_next
                );
                pool.observation_index = observation_index;
                pool.observation_cardinality = observation_cardinality;

                pool.liquidity = liquidity_math::add_delta(pool.liquidity, liquidity_delta);
                (
                    sqrt_price_math::get_amount_x_delta(
                        pool.sqrt_price,
                        tick_math::get_sqrt_price_at_tick(tick_upper_index),
                        liquidity_delta_abs,
                        add
                    ),
                    sqrt_price_math::get_amount_y_delta(
                        tick_math::get_sqrt_price_at_tick(tick_lower_index),
                        pool.sqrt_price,
                        liquidity_delta_abs,
                        add
                    ),
                )
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to left
                (
                    0,
                    sqrt_price_math::get_amount_y_delta(
                        tick_math::get_sqrt_price_at_tick(tick_lower_index),
                        tick_math::get_sqrt_price_at_tick(tick_upper_index),
                        liquidity_delta_abs,
                        add
                    ),
                )
            };
            (amount_x, amount_y)
        } else {
            (0, 0)
        }
    }

    fun update_position<X, Y>(
        pool: &mut Pool<X, Y>,
        position: &mut Position,
        liquidity_delta: I128
    ) {
        let (tick_lower_index, tick_upper_index) = (position::tick_lower_index(position), position::tick_upper_index(position));
        let (flipped_lower, flipped_upper) = if (!i128::eq(liquidity_delta, i128::zero())) {
            let (flipped_lower_, flipped_upper_) = (
                tick::update(
                    &mut pool.ticks,
                    tick_lower_index,
                    pool.tick_index,
                    liquidity_delta,
                    pool.fee_growth_global_x,
                    pool.fee_growth_global_y,
                    false,
                    pool.max_liquidity_per_tick
                ),
                tick::update(
                    &mut pool.ticks,
                    tick_upper_index,
                    pool.tick_index,
                    liquidity_delta,
                    pool.fee_growth_global_x,
                    pool.fee_growth_global_y,
                    true,
                    pool.max_liquidity_per_tick
                )
            );

            if (flipped_lower_) {
                tick_bitmap::flip_tick(&mut pool.tick_bitmap, tick_lower_index, pool.tick_spacing);
            };
            if (flipped_upper_) {
                tick_bitmap::flip_tick(&mut pool.tick_bitmap, tick_upper_index, pool.tick_spacing);
            };

            (flipped_lower_, flipped_upper_)
        } else {
            (false, false)
        };
        
        let (fee_growth_inside_x, fee_growth_inside_y) =
            tick::get_fee_growth_inside(&pool.ticks, tick_lower_index, tick_upper_index, pool.tick_index, pool.fee_growth_global_x, pool.fee_growth_global_y);

        position::update(position, liquidity_delta, fee_growth_inside_x, fee_growth_inside_y);

        // clear any tick data that is no longer needed
        if (i128::lt(liquidity_delta, i128::zero())) {
            if (flipped_lower) {
                tick::clear(&mut pool.ticks, tick_lower_index);
            };
            if (flipped_upper) {
                tick::clear(&mut pool.ticks, tick_upper_index);
            };
        };
    }

    fun check_pool_match<X, Y>(self: &Pool<X, Y>, id: ID) {
        if (object::id(self) != id) {
            abort E_POOL_ID_MISMATCH
        };
    }

    fun check_lock<X, Y>(self: &Pool<X, Y>) {
        if (self.locked) {
            abort E_POOL_ALREADY_LOCKED
        };
    }

    fun take<X, Y>(
        self: &mut Pool<X, Y>,
        amount_x: u64,
        amount_y: u64
    ): (Balance<X>, Balance<Y>) {
        (
            balance::split(df::borrow_mut<ReserveDfKey<X>, Balance<X>>(&mut self.id, ReserveDfKey<X> {}), amount_x),
            balance::split(df::borrow_mut<ReserveDfKey<Y>, Balance<Y>>(&mut self.id, ReserveDfKey<Y> {}), amount_y),
        )
    }

    fun put<X, Y>(
        self: &mut Pool<X, Y>,
        payment_x: Balance<X>,
        payment_y: Balance<Y>,
    ) {
        balance::join(df::borrow_mut(&mut self.id, ReserveDfKey<X> {}), payment_x);
        balance::join(df::borrow_mut(&mut self.id, ReserveDfKey<Y> {}), payment_y);
    }
}