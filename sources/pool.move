module flowx_clmm::pool {
    use std::vector;
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
    use flowx_clmm::i64::{Self, I64};
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
    const E_TICK_NOT_INITIALIZED: u64 = 8;

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
        reserve_x: Balance<CoinX>,
        reserve_y: Balance<CoinY>,
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

    struct SwapReceipt {
        pool_id: ID,
        amount_x_debt: u64,
        amount_y_debt: u64
    }

    struct FlashReceipt {
        pool_id: ID,
        amount_x: u64,
        amount_y: u64,
        fee_x: u64,
        fee_y: u64
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
        x_for_y: bool,
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

    struct Pay has copy, drop, store {
        sender: address,
        pool_id: ID,
        amount_x_debt: u64,
        amount_y_debt: u64,
        paid_x: u64,
        paid_y: u64
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
        sender: address,
        pool_id: ID,
        sqrt_price: u128,
        tick_index: I32
    }

    struct IncreaseObservationCardinalityNext has copy, drop, store {
        sender: address,
        pool_id: ID,
        observation_cardinality_next_old: u64,
        observation_cardinality_next_new: u64
    }

    public fun pool_id<X, Y>(self: &Pool<X, Y>): ID { object::id(self) }

    public fun coin_type_x<X, Y>(self: &Pool<X, Y>): TypeName { self.coin_type_x }

    public fun coin_type_y<X, Y>(self: &Pool<X, Y>): TypeName { self.coin_type_y }

    public fun sqrt_price_current<X, Y>(self: &Pool<X, Y>): u128 { self.sqrt_price }

    public fun tick_index_current<X, Y>(self: &Pool<X, Y>): I32 { self.tick_index }

    public fun observation_index<X, Y>(self: &Pool<X, Y>): u64 { self.observation_index }

    public fun observation_cardinality<X, Y>(self: &Pool<X, Y>): u64 { self.observation_cardinality }

    public fun observation_cardinality_next<X, Y>(self: &Pool<X, Y>): u64 { self.observation_cardinality_next }

    public fun tick_spacing<X, Y>(self: &Pool<X, Y>): u32 { self.tick_spacing }

    public fun max_liquidity_per_tick<X, Y>(self: &Pool<X, Y>): u128 { self.max_liquidity_per_tick }

    public fun protocol_fee_rate<X, Y>(self: &Pool<X, Y>): u64 { self.protocol_fee_rate }

    public fun swap_fee_rate<X, Y>(self: &Pool<X, Y>): u64 { self.swap_fee_rate }

    public fun fee_growth_global_x<X, Y>(self: &Pool<X, Y>): u128 { self.fee_growth_global_x }

    public fun fee_growth_global_y<X, Y>(self: &Pool<X, Y>): u128 { self.fee_growth_global_y }

    public fun protocol_fee_x<X, Y>(self: &Pool<X, Y>): u64 { self.protocol_fee_x }

    public fun protocol_fee_y<X, Y>(self: &Pool<X, Y>): u64 { self.protocol_fee_y }

    public fun liquidity<X, Y>(self: &Pool<X, Y>): u128 { self.liquidity }

    public fun borrow_ticks<X, Y>(self: &Pool<X, Y>): &Table<I32, TickInfo> { &self.ticks }

    public fun borrow_tick_bitmap<X, Y>(self: &Pool<X, Y>): &Table<I32, u256> { &self.tick_bitmap }

    public fun borrow_observations<X, Y>(self: &Pool<X, Y>): &vector<Observation> { &self.observations }

    public fun is_locked<X, Y>(self: &Pool<X, Y>): bool { self.locked }

    public fun reserves<X, Y>(self: &Pool<X, Y>): (u64, u64) {
        (balance::value(&self.reserve_x), balance::value(&self.reserve_y))
    }

    public fun swap_receipt_debts(receipt: &SwapReceipt): (u64, u64) { (receipt.amount_x_debt, receipt.amount_y_debt) }

    public fun flash_receipt_debts(receipt: &FlashReceipt): (u64, u64) {
        (receipt.amount_x + receipt.fee_x, receipt.amount_y + receipt.fee_y)
    }

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
            observation_index: 0,
            observation_cardinality: 0,
            observation_cardinality_next: 0,
            observations: vector::empty(),
            reserve_x: balance::zero(),
            reserve_y: balance::zero(),
            locked: true
        };
        pool
    }

    public fun initialize<X, Y>(
        self: &mut Pool<X, Y>,
        sqrt_price: u128,
        clock: &Clock,
        ctx: &TxContext
    ) {
        if (self.sqrt_price > 0) {
            abort E_POOL_ALREADY_INITIALIZED
        };

        let tick_index = tick_math::get_tick_at_sqrt_price(sqrt_price);
        self.tick_index = tick_index;
        self.sqrt_price = sqrt_price;

        let (cardinality, cardinality_next) =
            oracle::initialize(&mut self.observations, utils::to_seconds(clock::timestamp_ms(clock)));
        self.observation_cardinality = cardinality;
        self.observation_cardinality_next = cardinality_next;
        self.locked = false;

        event::emit(Initialize {
            sender: tx_context::sender(ctx),
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
        clock: &Clock,
        ctx: &TxContext
    ): (Balance<X>, Balance<Y>, SwapReceipt) {
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

        let (timestamp_s, computed_latest_observation) = (utils::to_seconds(clock::timestamp_ms(clock)), false);

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
                state.fee_growth_global = full_math_u128::wrapping_add(
                    state.fee_growth_global,
                    full_math_u128::mul_div_floor(
                        (step.fee_amount as u128),
                        (constants::get_q64() as u128),
                        state.liquidity
                    )
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
                    let (tick_cumulative, seconds_per_liquidity_cumulative) = if (!computed_latest_observation) {
                        computed_latest_observation = true;
                        oracle::observe_single(
                            &self.observations,
                            timestamp_s,
                            0,
                            self.tick_index,
                            self.observation_index,
                            self.liquidity,
                            self.observation_cardinality
                        )
                    } else {
                        (i64::zero(), 0)
                    };

                    let liquidity_net = tick::cross(
                        &mut self.ticks,
                        step.tick_index_next,
                        fee_growth_global_x,
                        fee_growth_global_y,
                        seconds_per_liquidity_cumulative,
                        tick_cumulative,
                        timestamp_s
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
            let (observation_index, observation_cardinality) = 
                oracle::write(
                    &mut self.observations,
                    self.observation_index,
                    timestamp_s,
                    self.tick_index,
                    self.liquidity,
                    self.observation_cardinality,
                    self.observation_cardinality_next,
                );
            self.sqrt_price = state.sqrt_price;
            self.tick_index = state.tick_index;
            self.observation_index = observation_index;
            self.observation_cardinality = observation_cardinality;
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

        let (x_out, y_out, receipt) = if (x_for_y) {
            let receipt = SwapReceipt {
                pool_id: object::id(self),
                amount_x_debt: amount_x,
                amount_y_debt: 0
            };
            let (taked_x, taked_y) = take(self, 0, amount_y);
            (taked_x, taked_y, receipt)
        } else {
             let receipt = SwapReceipt {
                pool_id: object::id(self),
                amount_x_debt: 0,
                amount_y_debt: amount_y
            };
            let (taked_x, taked_y) = take(self, amount_x, 0);
            (taked_x, taked_y, receipt)
        };

        event::emit(Swap {
            pool_id: object::id(self),
            sender: tx_context::sender(ctx),
            x_for_y,
            amount_x,
            amount_y,
            sqrt_price: state.sqrt_price,
            liquidity: state.liquidity,
            tick_index: state.tick_index
        });

        (x_out, y_out, receipt)
    }

    public fun pay<X, Y>(
        self: &mut Pool<X, Y>,
        receipt: SwapReceipt,
        payment_x: Balance<X>,
        payment_y: Balance<Y>,
        versioned: &mut Versioned,
        ctx: &TxContext
    ) {
        versioned::check_version_and_upgrade(versioned);
        check_pool_match(self, receipt.pool_id);

        let SwapReceipt { pool_id: _, amount_x_debt, amount_y_debt } = receipt;
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

        event::emit(Pay {
            sender: tx_context::sender(ctx),
            pool_id: object::id(self),
            amount_x_debt,
            amount_y_debt,
            paid_x: balance_x_after - balance_x_before,
            paid_y: balance_y_after - balance_y_before
        });
    }

    public fun flash<X, Y>(
        self: &mut Pool<X, Y>,
        amount_x: u64,
        amount_y: u64,
        versioned: &mut Versioned,
        ctx: &TxContext
    ): (Balance<X>, Balance<Y>, FlashReceipt) {
        versioned::check_version_and_upgrade(versioned);
        check_lock(self);

        self.locked = true;
        if (self.liquidity == 0) {
            abort E_INSUFFICIENT_LIQUIDITY
        };

        let (fee_x, fee_y) = (
            full_math_u64::mul_div_round(
                amount_x,
                self.swap_fee_rate,
                constants::get_fee_rate_denominator_value()
            ),
            full_math_u64::mul_div_round(
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
            FlashReceipt {
                pool_id: object::id(self),
                amount_x,
                amount_y,
                fee_x,
                fee_y
            }
        )
    }

    public fun repay<X, Y>(
        self: &mut Pool<X, Y>,
        receipt: FlashReceipt,
        payment_x: Balance<X>,
        payment_y: Balance<Y>,
        versioned: &mut Versioned,
        ctx: &TxContext
    ) {
        versioned::check_version_and_upgrade(versioned);
        check_pool_match(self, receipt.pool_id);
        
        let FlashReceipt { pool_id: _, amount_x, amount_y, fee_x, fee_y } = receipt;
        let (balance_x_before, balance_y_before) = reserves(self);
        put(self, payment_x, payment_y);
        let (balance_x_after, balance_y_after) = reserves(self);

        if (
            (balance_x_before + (amount_x + fee_x) > balance_x_after) ||
            (balance_y_before + (amount_y + fee_y) > balance_y_after)
        ) {
            abort E_INSUFFICIENT_INPUT_AMOUNT
        };

        // sub is safe because we know balanceAfter is gt balanceBefore by at least fee
        let paid_x = balance_x_after - (balance_x_before + amount_x);
        let paid_y = balance_y_after - (balance_y_before + amount_y);
        if (paid_x > 0) {
            let protocol_fee_rate_x = self.protocol_fee_rate % 16;
            let fee_x = if (protocol_fee_rate_x == 0) {
                0
            } else {
                paid_x / protocol_fee_rate_x
            };
            self.protocol_fee_x = self.protocol_fee_x + fee_x;
            self.fee_growth_global_x = full_math_u128::wrapping_add(
                self.fee_growth_global_x,
                full_math_u128::mul_div_floor(((paid_x - fee_x) as u128), (constants::get_q64() as u128), self.liquidity)
            );
        };
        if (paid_y > 0) {
            let protocol_fee_rate_y = self.protocol_fee_rate >> 4;
            let fee_y = if (protocol_fee_rate_y == 0) {
                0
            } else {
                paid_y / protocol_fee_rate_y
            };
            self.protocol_fee_y = self.protocol_fee_y + fee_y;
            self.fee_growth_global_y = full_math_u128::wrapping_add(
                self.fee_growth_global_y,
                full_math_u128::mul_div_floor(((paid_y - fee_y) as u128), (constants::get_q64() as u128), self.liquidity)
            );
        };

        self.locked = false;

        event::emit(Pay {
            sender: tx_context::sender(ctx),
            pool_id: object::id(self),
            amount_x_debt: (amount_x + fee_x),
            amount_y_debt: (amount_y + fee_y),
            paid_x,
            paid_y
        });
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

        event::emit(CollectProtocolFee {
            sender: tx_context::sender(ctx),
            pool_id: object::id(self),
            amount_x,
            amount_y
        });

        take(self, amount_x, amount_y)
    }

    public fun set_protocol_fee_rate<X, Y>(
        _: &AdminCap,
        self: &mut Pool<X, Y>,
        protocol_fee_rate_x: u64,
        protocol_fee_rate_y: u64,
        versioned: &mut Versioned,
        ctx: &TxContext
    ) {
        versioned::check_version_and_upgrade(versioned);
        check_lock(self);

        if (
            (protocol_fee_rate_x != 0 && (protocol_fee_rate_x < 4 || protocol_fee_rate_x > 10)) ||
            (protocol_fee_rate_y != 0 && (protocol_fee_rate_y < 4 || protocol_fee_rate_y > 10))
        ) {
            abort E_INVALID_PROTOCOL_FEE_RATE
        };
        self.protocol_fee_rate = protocol_fee_rate_x + (protocol_fee_rate_y << 4);

        event::emit(SetProtocolFeeRate {
            sender: tx_context::sender(ctx),
            pool_id: object::id(self),
            protocol_fee_rate_x_old: self.protocol_fee_rate % 16,
            protocol_fee_rate_y_old: self.protocol_fee_rate >> 4,
            protocol_fee_rate_x_new: protocol_fee_rate_x,
            protocol_fee_rate_y_new: protocol_fee_rate_y,
        });
    }
    
    public fun increase_observation_cardinality_next<X, Y>(
        self: &mut Pool<X, Y>,
        observation_cardinality_next: u64,
        versioned: &mut Versioned,
        ctx: &TxContext
    ) {
        versioned::check_version_and_upgrade(versioned);
        check_lock(self);

        let observation_cardinality_next_old = self.observation_cardinality_next;
        let observation_cardinality_next_new = 
            oracle::grow(&mut self.observations, observation_cardinality_next_old, observation_cardinality_next);
        self.observation_cardinality_next = observation_cardinality_next_new;
        
        event::emit(IncreaseObservationCardinalityNext {
            sender: tx_context::sender(ctx),
            pool_id: object::id(self),
            observation_cardinality_next_old,
            observation_cardinality_next_new
        })
    }

    public fun snapshot_cumulatives_inside<X, Y>(
        self: &Pool<X, Y>,
        tick_lower_index: I32,
        tick_upper_index: I32,
        clock: &Clock
    ): (I64, u256, u64) {
        tick::check_ticks(tick_lower_index, tick_upper_index);

        if (!tick::is_initialized(&self.ticks, tick_lower_index) || !tick::is_initialized(&self.ticks, tick_upper_index)) {
            abort E_TICK_NOT_INITIALIZED
        };

        let (tick_cumulative_lower, tick_cumulative_upper) = 
            (tick::get_tick_cumulative_out_side(&self.ticks, tick_lower_index), tick::get_tick_cumulative_out_side(&self.ticks, tick_upper_index));
        let (seconds_per_liquidity_out_side_lower, seconds_per_liquidity_out_side_upper) = 
            (tick::get_seconds_per_liquidity_out_side(&self.ticks, tick_lower_index), tick::get_seconds_per_liquidity_out_side(&self.ticks, tick_upper_index));
        let (seconds_out_side_lower, seconds_out_side_upper) = 
            (tick::get_seconds_out_side(&self.ticks, tick_lower_index), tick::get_seconds_out_side(&self.ticks, tick_upper_index));

        if (i32::lt(self.tick_index, tick_lower_index)) {
            (
                i64::sub(tick_cumulative_lower, tick_cumulative_upper),
                seconds_per_liquidity_out_side_lower - seconds_per_liquidity_out_side_upper,
                seconds_out_side_lower - seconds_out_side_upper
            )
        } else if (i32::lt(self.tick_index, tick_upper_index)) {
            let timestamp_s = utils::to_seconds(clock::timestamp_ms(clock));
            let (tick_cumulative, seconds_per_liquidity_cumulative) =
                oracle::observe_single(
                    &self.observations,
                    timestamp_s,
                    0,
                    self.tick_index,
                    self.observation_index,
                    self.liquidity,
                    self.observation_cardinality
                );
            (
                i64::sub(i64::sub(tick_cumulative, tick_cumulative_lower), tick_cumulative_upper),
                seconds_per_liquidity_cumulative - seconds_per_liquidity_out_side_lower - seconds_per_liquidity_out_side_upper,
                timestamp_s - seconds_out_side_lower - seconds_out_side_upper,
            )
        } else {
            (
                i64::sub(tick_cumulative_upper, tick_cumulative_lower),
                seconds_per_liquidity_out_side_upper - seconds_per_liquidity_out_side_lower,
                seconds_out_side_upper - seconds_out_side_lower
            )
        }
    }

    public fun observe<X, Y>(
        self: &Pool<X, Y>,
        seconds_agos: vector<u64>,
        clock: &Clock
    ): (vector<I64>, vector<u256>) {
        oracle::observe(
            &self.observations,
            utils::to_seconds(clock::timestamp_ms(clock)),
            seconds_agos,
            self.tick_index,
            self.observation_index,
            self.liquidity,
            self.observation_cardinality
        )
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

        update_position(pool, position, liquidity_delta, clock);

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
                    &mut pool.observations,
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
        liquidity_delta: I128,
        clock: &Clock,
    ) {
        let (tick_lower_index, tick_upper_index) = (position::tick_lower_index(position), position::tick_upper_index(position));
        let (flipped_lower, flipped_upper) = if (!i128::eq(liquidity_delta, i128::zero())) {
            let timestamp_s = utils::to_seconds(clock::timestamp_ms(clock));
            let (tick_cumulative, seconds_per_liquidity_cumulative) = oracle::observe_single(
                &pool.observations,
                timestamp_s,
                0,
                pool.tick_index,
                pool.observation_index,
                pool.liquidity,
                pool.observation_cardinality
            );

            let (flipped_lower_, flipped_upper_) = (
                tick::update(
                    &mut pool.ticks,
                    tick_lower_index,
                    pool.tick_index,
                    liquidity_delta,
                    pool.fee_growth_global_x,
                    pool.fee_growth_global_y,
                    seconds_per_liquidity_cumulative,
                    tick_cumulative,
                    timestamp_s,
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
                    seconds_per_liquidity_cumulative,
                    tick_cumulative,
                    timestamp_s,
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
            balance::split(&mut self.reserve_x, amount_x),
            balance::split(&mut self.reserve_y, amount_y),
        )
    }

    fun put<X, Y>(
        self: &mut Pool<X, Y>,
        payment_x: Balance<X>,
        payment_y: Balance<Y>,
    ) {
        balance::join(&mut self.reserve_x, payment_x);
        balance::join(&mut self.reserve_y, payment_y);
    }

    #[test_only]
    public fun create_for_testing<X, Y>(
        fee_rate: u64,
        tick_spacing: u32,
        ctx: &mut TxContext
    ): Pool<X, Y> {
        create<X, Y>(fee_rate, tick_spacing, ctx)
    }

    #[test_only]
    public fun destroy_for_testing<X, Y>(pool: Pool<X, Y>) {
        let Pool {
            id, coin_type_x: _, coin_type_y: _, sqrt_price: _, tick_index: _, observation_index: _, observation_cardinality: _,
            observation_cardinality_next: _, tick_spacing: _, max_liquidity_per_tick: _, protocol_fee_rate: _, swap_fee_rate: _,
            fee_growth_global_x: _, fee_growth_global_y: _, protocol_fee_x: _, protocol_fee_y: _, liquidity: _, ticks, tick_bitmap,
            observations, reserve_x, reserve_y, locked: _
        } = pool;
        object::delete(id);
        table::drop(ticks);
        table::drop(tick_bitmap);
        balance::destroy_for_testing(reserve_x);
        balance::destroy_for_testing(reserve_y);
    }

    #[test_only]
    public fun set_fee_growth_global_for_testing<X, Y>(
        pool: &mut Pool<X, Y>,
        fee_growth_global_x: u128,
        fee_growth_global_y: u128
    ) {
        pool.fee_growth_global_x = fee_growth_global_x;
        pool.fee_growth_global_y = fee_growth_global_y;
    }
}

#[test_only]
module flowx_clmm::test_pool {
    use std::vector;
    use sui::tx_context;
    use sui::sui::SUI;
    use sui::balance;
    use sui::clock;

    use flowx_clmm::i32::{Self, I32};
    use flowx_clmm::i64;
    use flowx_clmm::i128;
    use flowx_clmm::pool;
    use flowx_clmm::test_utils;
    use flowx_clmm::tick_math;
    use flowx_clmm::oracle;
    use flowx_clmm::position;
    use flowx_clmm::versioned;
    use flowx_clmm::tick;
    use flowx_clmm::constants;

    struct USDC has drop {}

    #[test]
    fun test_initialize() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let (fee_rate, tick_spacing) = (3000, 60);
    
        clock::set_for_testing(&mut clock, 100000);
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        let price = test_utils::encode_sqrt_price(1, 2);
        pool::initialize(&mut pool, price, &clock, &ctx);
        assert!(
            pool::sqrt_price_current(&pool) == price &&
            i32::eq(pool::tick_index_current(&pool), i32::neg_from(6932)) &&
            pool::observation_index(&pool) == 0 &&
            pool::observation_cardinality(&pool) == 1 &&
            pool::observation_cardinality_next(&pool) == 1,
            0
        );

        let observation = vector::borrow(pool::borrow_observations(&pool), 0);
        assert!(
            oracle::timestamp_s(observation) == 100 &&
            i64::eq(oracle::tick_cumulative(observation), i64::zero()) &&
            oracle::seconds_per_liquidity_cumulative(observation) == 0 &&
            oracle::is_initialized(observation),
            0
        );

        clock::destroy_for_testing(clock);
        pool::destroy_for_testing(pool);
    }

    #[test]
    fun test_add_liquidity_above_current_price() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);

        clock::set_for_testing(&mut clock, 100000);
        let (fee_rate, tick_spacing) = (3000, 60);
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 10), &clock, &ctx);
        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));

        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(3161), balance::create_for_testing(9996), balance::create_for_testing(1000), &mut versioned, &clock, &ctx
        );
        let (rx, ry) = pool::reserves(&pool);
        assert!(
            i32::eq(pool::tick_index_current(&pool), i32::neg_from(23028)) &&
            rx == 9996 && ry == 1000 && amount_x == 9996 && amount_y == 1000,
            0
        );
        position::destroy_for_testing(position);

        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(22980), i32::zero(), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(10000), balance::create_for_testing(21549),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        let (rx, ry) = pool::reserves(&pool);
        assert!(
            i32::eq(pool::tick_index_current(&pool), i32::neg_from(23028)) &&
            rx == 9996 + 21549 && ry == 1000 && amount_x == 21549 && amount_y == 0,
            0
        );
        position::destroy_for_testing(position);

        //max tick with max leverage
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::sub(max_tick, i32::from(tick_spacing)), max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(1 << 100), balance::create_for_testing(889231715489490855),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        let (rx, ry) = pool::reserves(&pool);
        assert!(
            i32::eq(pool::tick_index_current(&pool), i32::neg_from(23028)) &&
            rx == 9996 + 21549 + 889231715489490855 && ry == 1000 && amount_x == 889231715489490855 && amount_y == 0,
            0
        );
        position::destroy_for_testing(position);

        //works for max tick
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(22980), max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(10000), balance::create_for_testing(31549),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        let (rx, ry) = pool::reserves(&pool);
        assert!(
            i32::eq(pool::tick_index_current(&pool), i32::neg_from(23028)) &&
            rx == 9996 + 21549 + 889231715489490855 + 31549 && ry == 1000 && amount_x == 31549 && amount_y == 0,
            0
        );
        position::destroy_for_testing(position);

        //adds liquidity to liquidityGross
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(240), i32::zero(), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(100), balance::create_for_testing(2),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::neg_from(240)) == 100 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::zero()) == 10100 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::from(tick_spacing)) == 0 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::from(tick_spacing * 2)) == 0,
            0
        );
        position::destroy_for_testing(position);

        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(240), i32::from(tick_spacing), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(150), balance::create_for_testing(3),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::neg_from(240)) == 250 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::zero()) == 10100 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::from(tick_spacing)) == 150 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::from(tick_spacing * 2)) == 0,
            0
        );
        position::destroy_for_testing(position);

        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::zero(), i32::from(tick_spacing * 2), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(60), balance::create_for_testing(1),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::neg_from(240)) == 250 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::zero()) == 10160 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::from(tick_spacing)) == 150 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::from(tick_spacing * 2)) == 60,
            0
        );

        //removes liquidity from liquidityGross
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::neg_from(10), balance::create_for_testing(1),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::neg_from(240)) == 250 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::zero()) == 10150 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::from(tick_spacing)) == 150 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::from(tick_spacing * 2)) == 50,
            0
        );
        position::destroy_for_testing(position);

        //clears tick lower if last position is removed
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(300), i32::zero(), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(100), balance::create_for_testing(2),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::neg_from(300)) == 100 &&
            tick::is_initialized(pool::borrow_ticks(&pool), i32::neg_from(300)),
            0
        );
           
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::neg_from(100), balance::create_for_testing(2),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::neg_from(300)) == 0 &&
            !tick::is_initialized(pool::borrow_ticks(&pool), i32::neg_from(300)),
            0
        );
        position::destroy_for_testing(position);

        //clears tick upper if last position is removed
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::zero(), i32::from(180), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(100), balance::create_for_testing(2),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::from(180)) == 100 &&
            tick::is_initialized(pool::borrow_ticks(&pool), i32::from(180)),
            0
        );
           
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::neg_from(100), balance::create_for_testing(2),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::from(180)) == 0 &&
            !tick::is_initialized(pool::borrow_ticks(&pool), i32::from(180)),
            0
        );
        position::destroy_for_testing(position);

        //only clears the tick that is not used at all
        let position0 = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(360), i32::zero(), &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position0)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position0)),
            100,
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position0, i128::from(100), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
      
        let position1 = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(tick_spacing), i32::zero(), &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position1)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position1)),
            250,
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position1, i128::from(250), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        pool::modify_liquidity(
            &mut pool, &mut position0, i128::neg_from(100), balance::zero(), balance::zero(), &mut versioned, &clock, &ctx
        );
        
        assert!(
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::neg_from(360)) == 0 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::neg_from(tick_spacing)) == 250,
            0
        );

        position::destroy_for_testing(position0);
        position::destroy_for_testing(position1);

        //does not write an observation
        let observation_at_0 = vector::borrow(pool::borrow_observations(&pool), 0);
        assert!(
            i64::eq(oracle::tick_cumulative(observation_at_0), i64::zero()) &&
            oracle::seconds_per_liquidity_cumulative(observation_at_0) == 0 &&
            oracle::timestamp_s(observation_at_0) == 100,
            0
        );
        clock::increment_for_testing(&mut clock, 1000);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(480), i32::zero(), &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            100,
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(100), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let observation_at_0 = vector::borrow(pool::borrow_observations(&pool), 0);
        assert!(
            i64::eq(oracle::tick_cumulative(observation_at_0), i64::zero()) &&
            oracle::seconds_per_liquidity_cumulative(observation_at_0) == 0 &&
            oracle::timestamp_s(observation_at_0) == 100,
            0
        );

        clock::destroy_for_testing(clock);
        pool::destroy_for_testing(pool);
        versioned::destroy_for_testing(versioned);
    }

    #[test]
    fun test_add_liquidity_including_current_price() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);

        let (fee_rate, tick_spacing) = (3000, 60);
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 10), &clock, &ctx);
        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));

        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(3161), balance::create_for_testing(9996), balance::create_for_testing(1000), &mut versioned, &clock, &ctx
        );
        let (rx, ry) = pool::reserves(&pool);
        assert!(
            i32::eq(pool::tick_index_current(&pool), i32::neg_from(23028)) &&
            rx == 9996 && ry == 1000 && amount_x == 9996 && amount_y == 1000,
            0
        );
        position::destroy_for_testing(position);

        //price within range: transfers current price of both tokens
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool),
            i32::add(min_tick, i32::from(tick_spacing)), i32::sub(max_tick, i32::from(tick_spacing)), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(100), balance::create_for_testing(317), balance::create_for_testing(32), &mut versioned, &clock, &ctx
        );
        let (rx, ry) = pool::reserves(&pool);
        assert!(
            rx == 9996 + 317 && ry == 1000 + 32 && amount_x == 317 && amount_y == 32 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::add(min_tick, i32::from(tick_spacing))) == 100 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), i32::sub(max_tick, i32::from(tick_spacing))) == 100,
            0
        );
        position::destroy_for_testing(position);

        //works for min/max tick
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(10000), balance::create_for_testing(31623), balance::create_for_testing(3163), &mut versioned, &clock, &ctx
        );
        let (rx, ry) = pool::reserves(&pool);
        assert!(
            rx == 9996 + 317 + 31623 && ry == 1000 + 32 + 3163 && amount_x == 31623 && amount_y == 3163 &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), min_tick) == 3161 + 10000  &&
            tick::get_liquidity_gross(pool::borrow_ticks(&pool), min_tick) == 3161 + 10000,
            0
        );
        position::destroy_for_testing(position);

        //removing works
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(100), balance::create_for_testing(317), balance::create_for_testing(32), &mut versioned, &clock, &ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::neg_from(100), balance::create_for_testing(0), balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(amount_x == 316 && amount_y == 31, 0);
        position::destroy_for_testing(position);

        clock::destroy_for_testing(clock);
        pool::destroy_for_testing(pool);
        versioned::destroy_for_testing(versioned);
    }

    #[test]
    fun test_add_liquidity_below_current_price() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);

        let (fee_rate, tick_spacing) = (3000, 60);
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 10), &clock, &ctx);
        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));

        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(3161), balance::create_for_testing(9996), balance::create_for_testing(1000), &mut versioned, &clock, &ctx
        );
        let (rx, ry) = pool::reserves(&pool);
        assert!(
            i32::eq(pool::tick_index_current(&pool), i32::neg_from(23028)) &&
            rx == 9996 && ry == 1000 && amount_x == 9996 && amount_y == 1000,
            0
        );
        position::destroy_for_testing(position);

        //transfers token1 only
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool),
            i32::neg_from(46080), i32::neg_from(23040), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(10000), balance::create_for_testing(0), balance::create_for_testing(2162), &mut versioned, &clock, &ctx
        );
        let (rx, ry) = pool::reserves(&pool);
        assert!(
            rx == 9996 && ry == 1000 + 2162 && amount_x == 0 && amount_y == 2162,
            0
        );
        position::destroy_for_testing(position);

        //min tick with max leverage
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, i32::add(min_tick, i32::from(tick_spacing)), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(1 << 102), balance::create_for_testing(0),
            balance::create_for_testing(3556926712925126656), &mut versioned, &clock, &ctx
        );
        let (rx, ry) = pool::reserves(&pool);
        assert!(
            i32::eq(pool::tick_index_current(&pool), i32::neg_from(23028)) &&
            rx == 9996 && ry == 1000 + 2162 + 3556926712925126656 && amount_x == 0 && amount_y == 3556926712925126656,
            0
        );
        position::destroy_for_testing(position);

        //works for min tick
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, i32::neg_from(23040), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(10000), balance::create_for_testing(0),
            balance::create_for_testing(3161), &mut versioned, &clock, &ctx
        );
        let (rx, ry) = pool::reserves(&pool);
        assert!(
            i32::eq(pool::tick_index_current(&pool), i32::neg_from(23028)) &&
            rx == 9996 && ry == 1000 + 2162 + 3556926712925126656 + 3161 && amount_x == 0 && amount_y == 3161,
            0
        );
        position::destroy_for_testing(position);

        //removing works
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(46080), i32::neg_from(46020), &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(10000), balance::create_for_testing(0),
            balance::create_for_testing(4), &mut versioned, &clock, &ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::neg_from(10000), balance::create_for_testing(0),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        let (collected_x, collected_y) = pool::collect(
            &mut pool, &mut position,  constants::get_max_u64(), constants::get_max_u64(), &mut versioned, &mut ctx
        );
        
        assert!(
            balance::value(&collected_x) == 0 && balance::value(&collected_y) == 3,
            0
        );
        balance::destroy_for_testing(collected_x);
        balance::destroy_for_testing(collected_y);
        position::destroy_for_testing(position);

        clock::destroy_for_testing(clock);
        pool::destroy_for_testing(pool);
        versioned::destroy_for_testing(versioned);
    }


    #[test]
    fun test_remove_liquidity(){
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);

        let (fee_rate, tick_spacing) = (3000, 60);
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));

        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);

        //clears the tick if its the last position using it
        let (tick_lower_index, tick_upper_index) = (i32::add(min_tick, i32::from(tick_spacing)), i32::sub(max_tick, i32::from(tick_spacing)));
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), tick_lower_index, tick_upper_index, &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(1), balance::create_for_testing(1),
            balance::create_for_testing(1), &mut versioned, &clock, &ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::neg_from(1), balance::create_for_testing(0),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(
            !tick::is_initialized(pool::borrow_ticks(&pool), tick_lower_index) &&
            !tick::is_initialized(pool::borrow_ticks(&pool), tick_upper_index),
            0
        );
        position::destroy_for_testing(position);

        //clears only the lower tick if upper is still used
        let (tick_lower_index, tick_upper_index) = (i32::add(min_tick, i32::from(tick_spacing)), i32::sub(max_tick, i32::from(tick_spacing)));
        let position0 = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), tick_lower_index, tick_upper_index, &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position0, i128::from(1), balance::create_for_testing(1),
            balance::create_for_testing(1), &mut versioned, &clock, &ctx
        );

        let position1 = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::add(tick_lower_index, i32::from(tick_spacing)), tick_upper_index, &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position1, i128::from(1), balance::create_for_testing(1),
            balance::create_for_testing(1), &mut versioned, &clock, &ctx
        );

        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position0, i128::neg_from(1), balance::create_for_testing(0),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(
            !tick::is_initialized(pool::borrow_ticks(&pool), tick_lower_index) &&
            tick::is_initialized(pool::borrow_ticks(&pool), i32::add(tick_lower_index, i32::from(tick_spacing))) &&
            tick::is_initialized(pool::borrow_ticks(&pool), tick_upper_index),
            0
        );
         pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position1, i128::neg_from(1), balance::create_for_testing(0),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position0);
        position::destroy_for_testing(position1);

        //clears only the upper tick if lower is still used
        let (tick_lower_index, tick_upper_index) = (i32::add(min_tick, i32::from(tick_spacing)), i32::sub(max_tick, i32::from(tick_spacing)));
        let position0 = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), tick_lower_index, tick_upper_index, &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position0, i128::from(1), balance::create_for_testing(1),
            balance::create_for_testing(1), &mut versioned, &clock, &ctx
        );

        let position1 = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), tick_lower_index, i32::sub(tick_upper_index, i32::from(tick_spacing)), &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position1, i128::from(1), balance::create_for_testing(1),
            balance::create_for_testing(1), &mut versioned, &clock, &ctx
        );

        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position0, i128::neg_from(1), balance::create_for_testing(0),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        
        assert!(
            tick::is_initialized(pool::borrow_ticks(&pool), tick_lower_index) &&
            tick::is_initialized(pool::borrow_ticks(&pool), i32::sub(tick_upper_index, i32::from(tick_spacing))) &&
            !tick::is_initialized(pool::borrow_ticks(&pool), tick_upper_index),
            0
        );
        position::destroy_for_testing(position0);
        position::destroy_for_testing(position1);

        clock::destroy_for_testing(clock);
        pool::destroy_for_testing(pool);
        versioned::destroy_for_testing(versioned);
    }

    struct PositionTestCase has copy, drop, store {
        tick_lower_index: I32,
        tick_upper_index: I32,
        liquidity: u128
    }

    struct PoolTestcase has copy, drop, store {
        fee_rate: u64,
        tick_spacing: u32,
        starting_price: u128,
        positions: vector<PositionTestCase>,
        swap_test_cases: vector<SwapTestCase>,
        hint: u64,
    }

    struct SwapTestCase has copy, drop, store {
        x_for_y: bool,
        exact_in: bool,
        amount_x: u64,
        amount_y: u64,
        sqrt_price_limit: u128,
        amount_x_out: u64,
        amount_y_out: u64,
        sqrt_price_after: u128
    }

    #[test]
    fun test_swap() {
        let test_pools = vector<PoolTestcase> [
            //low fee, 1:1 price, 2e9 max range liquidity
            PoolTestcase {
                fee_rate: 500,
                tick_spacing: 10,
                starting_price: test_utils::encode_sqrt_price(1, 1),
                hint: 488123048,
                positions: vector<PositionTestCase> [
                    PositionTestCase {
                        tick_lower_index: test_utils::get_min_tick(10),
                        tick_upper_index: test_utils::get_max_tick(10),
                        liquidity: (test_utils::expand_to_9_decimals(2) as u128)
                    }
                ],
                swap_test_cases: vector<SwapTestCase> [
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: true,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 0,
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: 666444406,
                        sqrt_price_after: 12299879366966330045
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: true,
                        amount_x: 0,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: 666444405,
                        amount_y_out: 0,
                        sqrt_price_after: 27665504414910427430
                    },
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: false,
                        amount_x: 2001000510,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: test_utils::expand_to_9_decimals(1),
                        sqrt_price_after: 9223372019252014507
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: false,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 2001000508,
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: test_utils::expand_to_9_decimals(1),
                        amount_y_out: 0,
                        sqrt_price_after: 36893488189460835287
                    }
                ]
            },
            //medium fee, 10:1 price, 2e9 max range liquidity
            PoolTestcase {
                fee_rate: 3000,
                tick_spacing: 60,
                starting_price: test_utils::encode_sqrt_price(10, 1),
                hint: 367096991,
                positions: vector<PositionTestCase> [
                    PositionTestCase {
                        tick_lower_index: test_utils::get_min_tick(60),
                        tick_upper_index: test_utils::get_max_tick(60),
                        liquidity: (test_utils::expand_to_9_decimals(2) as u128)
                    }
                ],
                swap_test_cases: vector<SwapTestCase> [
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: true,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 0,
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: 3869747608,
                        sqrt_price_after: 22641604797571698249
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: true,
                        amount_x: 0,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: 86123526,
                        amount_y_out: 0,
                        sqrt_price_after: 67529428607879370328
                    },
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: false,
                        amount_x: 119138327,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: test_utils::expand_to_9_decimals(1),
                        sqrt_price_after: 49110354650280383040
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: false,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 8591531216544024189,
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: 632455515,
                        amount_y_out: 0,
                        sqrt_price_after: 79226673515401279992447579054
                    }
                ]
            },
            //medium fee, 1:10 price, 2e9 max range liquidity
            PoolTestcase {
                fee_rate: 3000,
                tick_spacing: 60,
                starting_price: test_utils::encode_sqrt_price(1, 10),
                hint: 290962043,
                positions: vector<PositionTestCase> [
                    PositionTestCase {
                        tick_lower_index: test_utils::get_min_tick(60),
                        tick_upper_index: test_utils::get_max_tick(60),
                        liquidity: (test_utils::expand_to_9_decimals(2) as u128)
                    }
                ],
                swap_test_cases: vector<SwapTestCase> [
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: true,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 0,
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: 86123526,
                        sqrt_price_after: 5039023340429007161
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: true,
                        amount_x: 0,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: 3869747611,
                        amount_y_out: 0,
                        sqrt_price_after: 15029074582521877101
                    },
                ]
            },
            //medium fee, 1:1 price, 0 liquidity, all liquidity around current price
            PoolTestcase {
                fee_rate: 3000,
                tick_spacing: 60,
                starting_price: test_utils::encode_sqrt_price(1, 1),
                hint: 682806233,
                positions: vector<PositionTestCase> [
                    PositionTestCase {
                        tick_lower_index: test_utils::get_min_tick(60),
                        tick_upper_index: i32::neg_from(60),
                        liquidity: (test_utils::expand_to_9_decimals(2) as u128)
                    },
                    PositionTestCase {
                        tick_lower_index: i32::from(60),
                        tick_upper_index: test_utils::get_max_tick(60),
                        liquidity: (test_utils::expand_to_9_decimals(2) as u128)
                    }
                ],
                swap_test_cases: vector<SwapTestCase> [
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: true,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 0,
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: 662011820,
                        sqrt_price_after: 12285508213010972842
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: true,
                        amount_x: 0,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: 662011820,
                        amount_y_out: 0,
                        sqrt_price_after: 27697866544955972927
                    },
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: false,
                        amount_x: 2024171065,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: test_utils::expand_to_9_decimals(1),
                        sqrt_price_after: 9168117490573172071
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: false,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 2024171065,
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: test_utils::expand_to_9_decimals(1),
                        amount_y_out: 0,
                        sqrt_price_after: 37115838368217148729
                    }
                ]
            },
            //medium fee, 1:1 price, additional liquidity around current price
            PoolTestcase {
                fee_rate: 3000,
                tick_spacing: 60,
                starting_price: test_utils::encode_sqrt_price(1, 1),
                hint: 594493098,
                positions: vector<PositionTestCase> [
                    PositionTestCase {
                        tick_lower_index: test_utils::get_min_tick(60),
                        tick_upper_index: test_utils::get_max_tick(60),
                        liquidity: (test_utils::expand_to_9_decimals(2) as u128)
                    },
                    PositionTestCase {
                        tick_lower_index: test_utils::get_min_tick(60),
                        tick_upper_index: i32::neg_from(60),
                        liquidity: (test_utils::expand_to_9_decimals(2) as u128)
                    },
                    PositionTestCase {
                        tick_lower_index: i32::from(60),
                        tick_upper_index: test_utils::get_max_tick(60),
                        liquidity: (test_utils::expand_to_9_decimals(2) as u128)
                    }
                ],
                swap_test_cases: vector<SwapTestCase> [
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: true,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 0,
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: 795933703,
                        sqrt_price_after: 14748520462876101118
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: true,
                        amount_x: 0,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: 795933703,
                        amount_y_out: 0,
                        sqrt_price_after: 23072305305299768375
                    },
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: false,
                        amount_x: 1342022155,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: test_utils::expand_to_9_decimals(1),
                        sqrt_price_after: 13807430777936327093
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: false,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 1342022155,
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: test_utils::expand_to_9_decimals(1),
                        amount_y_out: 0,
                        sqrt_price_after: 24644872199156331270
                    }
                ]
            },
            //low fee, large liquidity around current price (stable swap)
            PoolTestcase {
                fee_rate: 500,
                tick_spacing: 10,
                starting_price: test_utils::encode_sqrt_price(1, 1),
                hint: 690401096,
                positions: vector<PositionTestCase> [
                    PositionTestCase {
                        tick_lower_index: i32::neg_from(10),
                        tick_upper_index: i32::from(10),
                        liquidity: (test_utils::expand_to_9_decimals(2) as u128)
                    }
                ],
                swap_test_cases: vector<SwapTestCase> [
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: true,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 0,
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: 999700,
                        sqrt_price_after: 4295048017
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: true,
                        amount_x: 0,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: 999700,
                        amount_y_out: 0,
                        sqrt_price_after: 79226673515401279992447579054
                    },
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: false,
                        amount_x: 1000701,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: 999700,
                        sqrt_price_after: 4295048017
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: false,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 1000701,
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: 999700,
                        amount_y_out: 0,
                        sqrt_price_after: 79226673515401279992447579054
                    }
                ]
            },
            // medium fee, token0 liquidity only
            PoolTestcase {
                fee_rate: 3000,
                tick_spacing: 60,
                starting_price: test_utils::encode_sqrt_price(1, 1),
                hint: 522562707,
                positions: vector<PositionTestCase> [
                    PositionTestCase {
                        tick_lower_index: i32::zero(),
                        tick_upper_index: i32::from(60 * 2000),
                        liquidity: (test_utils::expand_to_9_decimals(2) as u128)
                    }
                ],
                swap_test_cases: vector<SwapTestCase> [
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: true,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 0,
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: 0,
                        sqrt_price_after: 4295048017
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: true,
                        amount_x: 0,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: 665331998,
                        amount_y_out: 0,
                        sqrt_price_after: 27642445994453763096
                    },
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: false,
                        amount_x: 0,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: 0,
                        sqrt_price_after: 4295048017
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: false,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 2006018054,
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: test_utils::expand_to_9_decimals(1),
                        amount_y_out: 0,
                        sqrt_price_after: 36893488147419103232
                    }
                ]
            },
            //medium fee, token1 liquidity only
            PoolTestcase {
                fee_rate: 3000,
                tick_spacing: 60,
                starting_price: test_utils::encode_sqrt_price(1, 1),
                hint: 108340506,
                positions: vector<PositionTestCase> [
                    PositionTestCase {
                        tick_lower_index: i32::neg_from(60 * 2000),
                        tick_upper_index: i32::zero(),
                        liquidity: (test_utils::expand_to_9_decimals(2) as u128)
                    }
                ],
                swap_test_cases: vector<SwapTestCase> [
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: true,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 0,
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: 665331998,
                        sqrt_price_after: 12310139521995029441
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: true,
                        amount_x: 0,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: 0,
                        amount_y_out: 0,
                        sqrt_price_after: 79226673515401279992447579054
                    },
                    SwapTestCase {
                        x_for_y: true,
                        exact_in: false,
                        amount_x: 2006018054,
                        amount_y: test_utils::expand_to_9_decimals(1),
                        sqrt_price_limit: tick_math::min_sqrt_price() + 1,
                        amount_x_out: 0,
                        amount_y_out: test_utils::expand_to_9_decimals(1),
                        sqrt_price_after: 9223372036854775808
                    },
                    SwapTestCase {
                        x_for_y: false,
                        exact_in: false,
                        amount_x: test_utils::expand_to_9_decimals(1),
                        amount_y: 0,
                        sqrt_price_limit: tick_math::max_sqrt_price() - 1,
                        amount_x_out: 0,
                        amount_y_out: 0,
                        sqrt_price_after: 79226673515401279992447579054
                    }
                ]
            },
        ];

        let (i, num_pools) = (0, vector::length(&test_pools));
        while(i < num_pools) {
            let pool_test_case = vector::borrow(&test_pools, i);
            let (j, num_tests) = (0, vector::length(&pool_test_case.swap_test_cases));
            while(j < num_tests) {
                let ctx = tx_context::new_from_hint(
                    @0x0, pool_test_case.hint + j, i + j, j + i, i + j
                );
                let clock = clock::create_for_testing(&mut ctx);
                let versioned = versioned::create_for_testing(&mut ctx);

                let pool = pool::create_for_testing<SUI, USDC>(pool_test_case.fee_rate, pool_test_case.tick_spacing, &mut ctx);
                pool::initialize(&mut pool, pool_test_case.starting_price, &clock, &ctx);

                let (k, num_positions) = (0, vector::length(&pool_test_case.positions));
                while(k < num_positions) {
                    let position_test_case = vector::borrow(&pool_test_case.positions, k);
                    let position = position::create_for_testing(
                        pool::pool_id(&pool), pool_test_case.fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool),
                        position_test_case.tick_lower_index, position_test_case.tick_upper_index, &mut ctx
                    );
                
                    let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
                        pool::sqrt_price_current(&pool),
                        tick_math::get_sqrt_price_at_tick(position_test_case.tick_lower_index),
                        tick_math::get_sqrt_price_at_tick(position_test_case.tick_upper_index),
                        position_test_case.liquidity,
                    );
                    pool::modify_liquidity<SUI, USDC>(
                        &mut pool, &mut position, i128::from(position_test_case.liquidity), balance::create_for_testing(amount_x),
                        balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
                    );
                    position::destroy_for_testing(position);

                    k = k + 1;
                };

                let (pool_balance_x_before, pool_balance_y_before) = pool::reserves(&pool);
                let swap_test_case = vector::borrow(&pool_test_case.swap_test_cases, j);
                let amount_specified = if (swap_test_case.x_for_y) {
                    if (swap_test_case.exact_in) {
                        swap_test_case.amount_x
                    } else {
                        swap_test_case.amount_y
                    }
                } else {
                    if (swap_test_case.exact_in) {
                        swap_test_case.amount_y
                    } else {
                        swap_test_case.amount_x
                    }
                };

                let (x_out, y_out, receipt) = pool::swap(
                    &mut pool, swap_test_case.x_for_y, swap_test_case.exact_in, amount_specified,
                    swap_test_case.sqrt_price_limit, &mut versioned, &clock, &ctx
                );
                let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
                pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);

                assert!(
                    balance::value(&x_out) == swap_test_case.amount_x_out && balance::value(&y_out) == swap_test_case.amount_y_out &&
                    amount_x_debt <= swap_test_case.amount_x && amount_y_debt <= swap_test_case.amount_y &&
                    pool::sqrt_price_current(&pool) == swap_test_case.sqrt_price_after,
                    0
                );
                balance::destroy_for_testing(x_out);
                balance::destroy_for_testing(y_out);

                clock::destroy_for_testing(clock);
                pool::destroy_for_testing(pool);
                versioned::destroy_for_testing(versioned);

                j = j + 1;
            };
            i = i + 1;
        }
    }

    #[test]
    fun test_increase_observation_cardinality_next() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);

        clock::set_for_testing(&mut clock, 100000);
        let (fee_rate, tick_spacing) = (3000, 60);
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
    
        //oracle starting state after initialization
        assert!(
            pool::observation_cardinality(&pool) == 1 && pool::observation_cardinality_next(&pool) == 1 &&
            pool::observation_index(&pool) == 0,
            0
        );

        let observation_at_0 = vector::borrow(pool::borrow_observations(&pool), 0);
        assert!(
            oracle::timestamp_s(observation_at_0) == 100 && i64::eq(oracle::tick_cumulative(observation_at_0), i64::zero()) &&
            oracle::is_initialized(observation_at_0) && oracle::seconds_per_liquidity_cumulative(observation_at_0) == 0,
            0
        );

        //increases observation cardinality next
        pool::increase_observation_cardinality_next(&mut pool, 2, &mut versioned, &ctx);
        assert!(
            pool::observation_cardinality(&pool) == 1 && pool::observation_cardinality_next(&pool) == 2 &&
            pool::observation_index(&pool) == 0,
            0
        );

        //is no op if target is already exceeded
        pool::increase_observation_cardinality_next(&mut pool, 5, &mut versioned, &ctx);
        pool::increase_observation_cardinality_next(&mut pool, 3, &mut versioned, &ctx);
        assert!(
            pool::observation_cardinality(&pool) == 1 && pool::observation_cardinality_next(&pool) == 5 &&
            pool::observation_index(&pool) == 0,
            0
        );

        clock::destroy_for_testing(clock);
        pool::destroy_for_testing(pool);
        versioned::destroy_for_testing(versioned);
    }

    #[test]
    #[expected_failure(abort_code = flowx_clmm::pool::E_POOL_ALREADY_LOCKED)]
    public fun test_increase_observation_cardinality_next_if_not_initialize() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);

        clock::set_for_testing(&mut clock, 100);
        let (fee_rate, tick_spacing) = (3000, 60);
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
    
        //increases observation cardinality next
        pool::increase_observation_cardinality_next(&mut pool, 2, &mut versioned, &ctx);

        clock::destroy_for_testing(clock);
        pool::destroy_for_testing(pool);
        versioned::destroy_for_testing(versioned);
    }

    #[test]
    fun test_set_protocol_fee() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let admin_cap = flowx_clmm::admin_cap::create_for_testing(&mut ctx);

        clock::set_for_testing(&mut clock, 10000);
        let (fee_rate, tick_spacing) = (3000, 60);
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);

        //succeeds for fee of 4
        pool::set_protocol_fee_rate(&admin_cap, &mut pool, 4, 4, &mut versioned, &ctx);
        assert!(pool::protocol_fee_rate(&pool) == 68, 0);

        //succeeds for fee of 10
        pool::set_protocol_fee_rate(&admin_cap, &mut pool, 10, 10, &mut versioned, &ctx);
        assert!(pool::protocol_fee_rate(&pool) == 170, 0);

        //succeeds for fee of 7
        pool::set_protocol_fee_rate(&admin_cap, &mut pool, 7, 7, &mut versioned, &ctx);
        assert!(pool::protocol_fee_rate(&pool) == 119, 0);

        //can turn off protocol fee
        pool::set_protocol_fee_rate(&admin_cap, &mut pool, 0, 0, &mut versioned, &ctx);
        assert!(pool::protocol_fee_rate(&pool) == 0, 0);

        clock::destroy_for_testing(clock);
        pool::destroy_for_testing(pool);
        versioned::destroy_for_testing(versioned);
        flowx_clmm::admin_cap::destroy_for_testing(admin_cap);
    }

    #[test]
    fun set_test_observe() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let admin_cap = flowx_clmm::admin_cap::create_for_testing(&mut ctx);

        clock::set_for_testing(&mut clock, 10000);
        let (fee_rate, tick_spacing) = (3000, 60);
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);

        //current tick accumulator increases by tick over time
        let (tick_cumulatives, _) = pool::observe(&pool, vector::singleton(0), &clock);
        assert!(i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::zero()), 0);

        clock::increment_for_testing(&mut clock, 10000);
        let (tick_cumulatives, _) = pool::observe(&pool, vector::singleton(0), &clock);
        assert!(i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::zero()), 0);
        pool::destroy_for_testing(pool);

        //current tick accumulator after single swap
        // moves to tick -1
        clock::set_for_testing(&mut clock, 20000);
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, true, true, 1000, tick_math::min_sqrt_price() + 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);
        clock::increment_for_testing(&mut clock, 4000);
        let (tick_cumulatives, _) = pool::observe(&pool, vector::singleton(0), &clock);
        assert!(i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::neg_from(4)), 0);
        pool::destroy_for_testing(pool);

        //current tick accumulator after two swaps
        clock::set_for_testing(&mut clock, 30000);
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, true, true, test_utils::expand_to_9_decimals(1) / 2, tick_math::min_sqrt_price() + 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);
        assert!(i32::eq(pool::tick_index_current(&pool), i32::neg_from(4452)), 0);
        clock::increment_for_testing(&mut clock, 4000);
        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, false, true, test_utils::expand_to_9_decimals(1) / 4, tick_math::max_sqrt_price() - 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);
        assert!(i32::eq(pool::tick_index_current(&pool), i32::neg_from(1558)), 0);
        clock::increment_for_testing(&mut clock, 6000);
        let (tick_cumulatives, _) = pool::observe(&pool, vector::singleton(0), &clock);
        assert!(i64::eq(*vector::borrow(&tick_cumulatives, 0), i64::neg_from(27156)), 0);
        pool::destroy_for_testing(pool);

        clock::destroy_for_testing(clock);
        versioned::destroy_for_testing(versioned);
        flowx_clmm::admin_cap::destroy_for_testing(admin_cap);
    }

    #[test]
    fun test_k_implicit() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let admin_cap = flowx_clmm::admin_cap::create_for_testing(&mut ctx);

        clock::set_for_testing(&mut clock, 10000);
        let (fee_rate, tick_spacing) = (3000, 60);
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        assert!(pool::liquidity(&pool) == 0, 0);
        
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        assert!(pool::liquidity(&pool) == 2000000000, 0);
        pool::destroy_for_testing(pool);

        //returns in supply in range
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(tick_spacing), i32::from(tick_spacing), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(3000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        assert!(pool::liquidity(&pool) == 5000000000, 0);
        pool::destroy_for_testing(pool);

        //excludes supply at tick above current tick
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::from(tick_spacing), i32::from(tick_spacing * 2), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(3000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        assert!(pool::liquidity(&pool) == 2000000000, 0);
        pool::destroy_for_testing(pool);

        //excludes supply at tick below current tick
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(tick_spacing * 2), i32::neg_from(tick_spacing), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(3000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        assert!(pool::liquidity(&pool) == 2000000000, 0);
        pool::destroy_for_testing(pool);

        //updates correctly when exiting range
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let k_before = pool::liquidity(&pool);
        assert!(k_before == 2000000000, 0);

        // add liquidity at and above current tick
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(0), i32::from(tick_spacing), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(1000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let k_after = pool::liquidity(&pool);
        assert!(k_after == 3000000000, 0);

        // swap toward the left (just enough for the tick transition function to trigger)
        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, true, true, 1, tick_math::min_sqrt_price() + 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);
        assert!(i32::eq(pool::tick_index_current(&pool), i32::neg_from(1)), 0);
        let k_after_swap = pool::liquidity(&pool);
        assert!(k_after_swap == 2000000000, 0);
        pool::destroy_for_testing(pool);

        //updates correctly when entering range
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let k_before = pool::liquidity(&pool);
        assert!(k_before == 2000000000, 0);

        //add liquidity below the current tick
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(tick_spacing), i32::zero(), &mut ctx
        );
        let (amount_x, amount_y) = pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(1000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let k_after = pool::liquidity(&pool);
        assert!(k_after == k_before, 0);

        // swap toward the left (just enough for the tick transition function to trigger)
        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, true, true, 1, tick_math::min_sqrt_price() + 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);
        assert!(i32::eq(pool::tick_index_current(&pool), i32::neg_from(1)), 0);
        let k_after_swap = pool::liquidity(&pool);
        assert!(k_after_swap == 3000000000, 0);
        pool::destroy_for_testing(pool);

        clock::destroy_for_testing(clock);
        versioned::destroy_for_testing(versioned);
        flowx_clmm::admin_cap::destroy_for_testing(admin_cap);
    }

    #[test]
    fun test_limit_orders() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let admin_cap = flowx_clmm::admin_cap::create_for_testing(&mut ctx);

        clock::set_for_testing(&mut clock, 10000);
        let (fee_rate, tick_spacing) = (3000, 60);
        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));

        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);

        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::zero(), i32::from(120), &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(1000000000), balance::create_for_testing(5981738),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );

        //limit selling x for y at tick 0 thru 1
        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, false, true, test_utils::expand_to_9_decimals(2), tick_math::max_sqrt_price() - 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);

        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::neg_from(1000000000), balance::create_for_testing(5981738),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(position::coins_owed_y(&position) == 6035841, 0);
        let (collected_x, collected_y) =
            pool::collect(&mut pool, &mut position, constants::get_max_u64(), constants::get_max_u64(), &mut versioned, &ctx);
        assert!(balance::value(&collected_x) == 0 && balance::value(&collected_y) == 6035841, 0);
        balance::destroy_for_testing(collected_x);
        balance::destroy_for_testing(collected_y);
        position::destroy_for_testing(position);
        pool::destroy_for_testing(pool);

        //limit selling y for x at tick 0 thru -1
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        assert!(pool::liquidity(&pool) == 0, 0);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        assert!(pool::liquidity(&pool) == 2000000000, 0);

        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(120), i32::zero(), &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(1000000000), balance::create_for_testing(0),
            balance::create_for_testing(5981738), &mut versioned, &clock, &ctx
        );

        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, true, true, test_utils::expand_to_9_decimals(2), tick_math::min_sqrt_price() + 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);

        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::neg_from(1000000000), balance::create_for_testing(5981738),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(position::coins_owed_x(&position) == 6035841, 0);
        let (collected_x, collected_y) =
            pool::collect(&mut pool, &mut position, constants::get_max_u64(), constants::get_max_u64(), &mut versioned, &ctx);
        assert!(balance::value(&collected_x) == 6035841 && balance::value(&collected_y) == 0, 0);
        balance::destroy_for_testing(collected_x);
        balance::destroy_for_testing(collected_y);
        position::destroy_for_testing(position);
        pool::destroy_for_testing(pool);

        clock::destroy_for_testing(clock);
        versioned::destroy_for_testing(versioned);
        flowx_clmm::admin_cap::destroy_for_testing(admin_cap);
    }

    #[test]
    fun test_fee_is_on() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let admin_cap = flowx_clmm::admin_cap::create_for_testing(&mut ctx);

        clock::set_for_testing(&mut clock, 10000);
        let (fee_rate, tick_spacing) = (3000, 60);
        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));

        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        pool::set_protocol_fee_rate(&admin_cap, &mut pool, 6, 6, &mut versioned, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);

        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::zero(), i32::from(120), &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(1000000000), balance::create_for_testing(5981738),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );

        //limit selling x for y at tick 0 thru 1
        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, false, true, test_utils::expand_to_9_decimals(2), tick_math::max_sqrt_price() - 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);

        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::neg_from(1000000000), balance::create_for_testing(5981738),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(position::coins_owed_y(&position) == 6032823, 0);
        let (collected_x, collected_y) =
            pool::collect(&mut pool, &mut position, constants::get_max_u64(), constants::get_max_u64(), &mut versioned, &ctx);
        assert!(balance::value(&collected_x) == 0 && balance::value(&collected_y) == 6032823, 0);
        balance::destroy_for_testing(collected_x);
        balance::destroy_for_testing(collected_y);
        position::destroy_for_testing(position);
        pool::destroy_for_testing(pool);

        //limit selling y for x at tick 0 thru -1
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        assert!(pool::liquidity(&pool) == 0, 0);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        pool::set_protocol_fee_rate(&admin_cap, &mut pool, 6, 6, &mut versioned, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(2000000000),
            balance::create_for_testing(2000000000), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        assert!(pool::liquidity(&pool) == 2000000000, 0);

        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::neg_from(120), i32::zero(), &mut ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(1000000000), balance::create_for_testing(0),
            balance::create_for_testing(5981738), &mut versioned, &clock, &ctx
        );

        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, true, true, test_utils::expand_to_9_decimals(2), tick_math::min_sqrt_price() + 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);

        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::neg_from(1000000000), balance::create_for_testing(5981738),
            balance::create_for_testing(0), &mut versioned, &clock, &ctx
        );
        assert!(position::coins_owed_x(&position) == 6032823, 0);
        let (collected_x, collected_y) =
            pool::collect(&mut pool, &mut position, constants::get_max_u64(), constants::get_max_u64(), &mut versioned, &ctx);
        assert!(balance::value(&collected_x) == 6032823 && balance::value(&collected_y) == 0, 0);
        balance::destroy_for_testing(collected_x);
        balance::destroy_for_testing(collected_y);
        position::destroy_for_testing(position);
        pool::destroy_for_testing(pool);

        clock::destroy_for_testing(clock);
        versioned::destroy_for_testing(versioned);
        flowx_clmm::admin_cap::destroy_for_testing(admin_cap);
    }

    #[test]
    fun test_collect() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let admin_cap = flowx_clmm::admin_cap::create_for_testing(&mut ctx);

        clock::set_for_testing(&mut clock, 10000);
        let (fee_rate, tick_spacing) = (500, 10);
        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));

        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        
        //works with multiple LPs
        let position0 = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position0)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position0)),
            1000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position0, i128::from(1000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        let position1 = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), i32::add(min_tick, i32::from(tick_spacing)), i32::sub(max_tick, i32::from(tick_spacing)), &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position1)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position1)),
            2000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position1, i128::from(2000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );

        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, true, true, test_utils::expand_to_9_decimals(1), tick_math::min_sqrt_price() + 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);

        //poke positions
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position0, i128::from(0), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position1, i128::from(0), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        assert!(
            position::coins_owed_x(&position0) == 166666 && position::coins_owed_x(&position1) == 333333,
            0
        );

        position::destroy_for_testing(position0);
        position::destroy_for_testing(position1);
        pool::destroy_for_testing(pool);

        //works across large increases
        //(max_u64 - 1) * 2**64 / 1e9
        //https://www.wolframalpha.com/input?i=%282**64-+1%29+*+2**64%2F+1e9
        let magic_number = 340282366920938463444927863358;

        //works just before the cap binds
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            1000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(1000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        pool::set_fee_growth_global_for_testing(&mut pool, magic_number, 0);
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::zero(), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        assert!(
            position::coins_owed_x(&position) == constants::get_max_u64() - 1 &&
            position::coins_owed_y(&position) == 0,
            0
        );
        position::destroy_for_testing(position);
        pool::destroy_for_testing(pool);

        //works just after the cap binds
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            1000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(1000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        pool::set_fee_growth_global_for_testing(&mut pool, magic_number + 1, 0);
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::zero(), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        assert!(
            position::coins_owed_x(&position) == constants::get_max_u64() &&
            position::coins_owed_y(&position) == 0,
            0
        );
        position::destroy_for_testing(position);
        pool::destroy_for_testing(pool);

        //works across overflow boundaries
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        pool::set_fee_growth_global_for_testing(&mut pool, constants::get_max_u128(), constants::get_max_u128());
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            10000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(10000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, true, true, test_utils::expand_to_9_decimals(1), tick_math::min_sqrt_price() + 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::zero(), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        assert!(
            position::coins_owed_x(&position) == 499999 &&
            position::coins_owed_y(&position) == 0,
            0
        );
        position::destroy_for_testing(position);
        pool::destroy_for_testing(pool);

        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        pool::set_fee_growth_global_for_testing(&mut pool, constants::get_max_u128(), constants::get_max_u128());
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            10000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(10000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, false, true, test_utils::expand_to_9_decimals(1), tick_math::max_sqrt_price() - 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::zero(), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        assert!(
            position::coins_owed_x(&position) == 0 &&
            position::coins_owed_y(&position) == 499999,
            0
        );
        position::destroy_for_testing(position);
        pool::destroy_for_testing(pool);

        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        pool::set_fee_growth_global_for_testing(&mut pool, constants::get_max_u128(), constants::get_max_u128());
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            10000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(10000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, true, true, test_utils::expand_to_9_decimals(1), tick_math::min_sqrt_price() + 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);
        let (x_out, y_out, receipt) = pool::swap(
            &mut pool, false, true, test_utils::expand_to_9_decimals(1), tick_math::max_sqrt_price() - 1, &mut versioned, &clock, &ctx
        );
        let (amount_x_debt, amount_y_debt) = pool::swap_receipt_debts(&receipt);
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::pay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::zero(), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        assert!(
            position::coins_owed_x(&position) == 499999 &&
            position::coins_owed_y(&position) == 500000,
            0
        );
        position::destroy_for_testing(position);
        pool::destroy_for_testing(pool);

        clock::destroy_for_testing(clock);
        versioned::destroy_for_testing(versioned);
        flowx_clmm::admin_cap::destroy_for_testing(admin_cap);
    }

    #[test]
    fun test_flash() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let admin_cap = flowx_clmm::admin_cap::create_for_testing(&mut ctx);

        clock::set_for_testing(&mut clock, 10000);
        let (fee_rate, tick_spacing) = (3000, 60);
        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));

        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            2000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        
        //
        let (x_out, y_out, receipt) = pool::flash(&mut pool, 1001, 2001, &mut versioned, &ctx);
        let (amount_x_debt, amount_y_debt) = pool::flash_receipt_debts(&receipt);
        assert!(
            balance::value(&x_out) == 1001 && balance::value(&y_out) == 2001 &&
            amount_x_debt == 1004 && amount_y_debt == 2007,
            0
        );
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::repay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);

        //can flash only token0
        let (x_out, y_out, receipt) = pool::flash(&mut pool, 1000, 0, &mut versioned, &ctx);
        let (amount_x_debt, amount_y_debt) = pool::flash_receipt_debts(&receipt);
        assert!(
            balance::value(&x_out) == 1000 && balance::value(&y_out) == 0 &&
            amount_x_debt == 1003 && amount_y_debt == 0,
            0
        );
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::repay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);

        //can flash only token1
        let (x_out, y_out, receipt) = pool::flash(&mut pool, 0, 1000, &mut versioned, &ctx);
        let (amount_x_debt, amount_y_debt) = pool::flash_receipt_debts(&receipt);
        assert!(
            balance::value(&x_out) == 0 && balance::value(&y_out) == 1000 &&
            amount_x_debt == 0 && amount_y_debt == 1003,
            0
        );
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::repay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);

        //can flash entire token balance
        let (reserve_x, reserve_y) = pool::reserves(&pool);
        let (x_out, y_out, receipt) = pool::flash(&mut pool, reserve_x, reserve_y, &mut versioned, &ctx);
        let (amount_x_debt, amount_y_debt) = pool::flash_receipt_debts(&receipt);
        pool::repay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);
        assert!(
            balance::value(&x_out) == reserve_x && balance::value(&y_out) == reserve_y &&
            amount_x_debt == 2006000006 && amount_y_debt == 2006000009,
            0
        );
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);

        //no-op if both amounts are 0
        let (x_out, y_out, receipt) = pool::flash(&mut pool, 0, 0, &mut versioned, &ctx);
        let (amount_x_debt, amount_y_debt) = pool::flash_receipt_debts(&receipt);
        assert!(
            balance::value(&x_out) == 0 && balance::value(&y_out) == 0 &&
            amount_x_debt == 0 && amount_y_debt == 0,
            0
        );
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::repay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);
        pool::destroy_for_testing(pool);

        //increases the fee growth by the expected amount
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            2000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let (x_out, y_out, receipt) = pool::flash(&mut pool, 1001, 2002, &mut versioned, &ctx);
        let (amount_x_debt, amount_y_debt) = pool::flash_receipt_debts(&receipt);
        pool::repay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);
        assert!(
            pool::fee_growth_global_x(&pool) == (3 * (1u128 << 64) / 2000000000) &&
            pool::fee_growth_global_y(&pool) == (6 * (1 << 64) / 2000000000),
            0
        );
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::destroy_for_testing(pool);

        //allows donating token0
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            2000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let (x_out, y_out, receipt) = pool::flash(&mut pool, 0, 0, &mut versioned, &ctx);
        let (amount_x_debt, amount_y_debt) = pool::flash_receipt_debts(&receipt);
        pool::repay(&mut pool, receipt, balance::create_for_testing(100), balance::create_for_testing(0), &mut versioned, &ctx);
        assert!(
            balance::value(&x_out) == 0 && balance::value(&y_out) == 0 &&
            pool::fee_growth_global_x(&pool) == (100 * (1u128 << 64) / 2000000000) &&
            pool::fee_growth_global_y(&pool) == 0,
            0
        );
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::destroy_for_testing(pool);

        //allows donating token1
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            2000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let (x_out, y_out, receipt) = pool::flash(&mut pool, 0, 0, &mut versioned, &ctx);
        let (amount_x_debt, amount_y_debt) = pool::flash_receipt_debts(&receipt);
        pool::repay(&mut pool, receipt, balance::create_for_testing(0), balance::create_for_testing(100), &mut versioned, &ctx);
        assert!(
            balance::value(&x_out) == 0 && balance::value(&y_out) == 0 &&
            pool::fee_growth_global_x(&pool) == 0 &&
            pool::fee_growth_global_y(&pool) == (100 * (1u128 << 64) / 2000000000),
            0
        );
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::destroy_for_testing(pool);

        //allows donating token0 and token1 together
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            2000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let (x_out, y_out, receipt) = pool::flash(&mut pool, 0, 0, &mut versioned, &ctx);
        let (amount_x_debt, amount_y_debt) = pool::flash_receipt_debts(&receipt);
        pool::repay(&mut pool, receipt, balance::create_for_testing(100), balance::create_for_testing(200), &mut versioned, &ctx);
        assert!(
            balance::value(&x_out) == 0 && balance::value(&y_out) == 0 &&
            pool::fee_growth_global_x(&pool) == (100 * (1u128 << 64) / 2000000000) &&
            pool::fee_growth_global_y(&pool) == (200 * (1u128 << 64) / 2000000000),
            0
        );
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::destroy_for_testing(pool);

        clock::destroy_for_testing(clock);
        versioned::destroy_for_testing(versioned);
        flowx_clmm::admin_cap::destroy_for_testing(admin_cap);
    }

    #[test]
    fun test_flash_fee_on() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let versioned = versioned::create_for_testing(&mut ctx);
        let admin_cap = flowx_clmm::admin_cap::create_for_testing(&mut ctx);

        clock::set_for_testing(&mut clock, 10000);
        let (fee_rate, tick_spacing) = (3000, 60);
        let (min_tick, max_tick) = (test_utils::get_min_tick(tick_spacing), test_utils::get_max_tick(tick_spacing));

        //increases the fee growth by the expected amount
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        pool::set_protocol_fee_rate(&admin_cap, &mut pool, 6, 6, &mut versioned, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            2000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let (x_out, y_out, receipt) = pool::flash(&mut pool, 2002, 4004, &mut versioned, &ctx);
        let (amount_x_debt, amount_y_debt) = pool::flash_receipt_debts(&receipt);
        pool::repay(&mut pool, receipt, balance::create_for_testing(amount_x_debt), balance::create_for_testing(amount_y_debt), &mut versioned, &ctx);
        assert!(
            pool::fee_growth_global_x(&pool) == (5 * (1u128 << 64) / 2000000000) &&
            pool::fee_growth_global_y(&pool) == (10 * (1u128 << 64) / 2000000000) &&
            pool::protocol_fee_x(&pool) == 1 && pool::protocol_fee_y(&pool) == 2,
            0
        );
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::destroy_for_testing(pool);

        //allows donating token0
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        pool::set_protocol_fee_rate(&admin_cap, &mut pool, 6, 6, &mut versioned, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            2000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let (x_out, y_out, receipt) = pool::flash(&mut pool, 0, 0, &mut versioned, &ctx);
        let (amount_x_debt, amount_y_debt) = pool::flash_receipt_debts(&receipt);
        pool::repay(&mut pool, receipt, balance::create_for_testing(100), balance::create_for_testing(0), &mut versioned, &ctx);
        assert!(
            pool::fee_growth_global_x(&pool) == (84 * (1u128 << 64) / 2000000000) &&
            pool::fee_growth_global_y(&pool) == 0 &&
            pool::protocol_fee_x(&pool) == 16 && pool::protocol_fee_y(&pool) == 0,
            0
        );
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::destroy_for_testing(pool);

        //allows donating token1
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        pool::set_protocol_fee_rate(&admin_cap, &mut pool, 6, 6, &mut versioned, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            2000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let (x_out, y_out, receipt) = pool::flash(&mut pool, 0, 0, &mut versioned, &ctx);
        let (amount_x_debt, amount_y_debt) = pool::flash_receipt_debts(&receipt);
        pool::repay(&mut pool, receipt, balance::create_for_testing(0), balance::create_for_testing(100), &mut versioned, &ctx);
        assert!(
            pool::fee_growth_global_x(&pool) == 0 &&
            pool::fee_growth_global_y(&pool) == (84 * (1u128 << 64) / 2000000000) &&
            pool::protocol_fee_x(&pool) == 0 && pool::protocol_fee_y(&pool) == 16,
            0
        );
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::destroy_for_testing(pool);

        //allows donating token0 and token1 together
        let pool = pool::create_for_testing<SUI, USDC>(fee_rate, tick_spacing, &mut ctx);
        pool::initialize(&mut pool, test_utils::encode_sqrt_price(1, 1), &clock, &ctx);
        pool::set_protocol_fee_rate(&admin_cap, &mut pool, 6, 6, &mut versioned, &ctx);
        let position = position::create_for_testing(
            pool::pool_id(&pool), fee_rate, pool::coin_type_x(&pool), pool::coin_type_y(&pool), min_tick, max_tick, &mut ctx
        );
        let (amount_x, amount_y) = flowx_clmm::liquidity_math::get_amounts_for_liquidity(
            pool::sqrt_price_current(&pool),
            tick_math::get_sqrt_price_at_tick(position::tick_lower_index(&position)),
            tick_math::get_sqrt_price_at_tick(position::tick_upper_index(&position)),
            2000000000,
        );
        pool::modify_liquidity<SUI, USDC>(
            &mut pool, &mut position, i128::from(2000000000), balance::create_for_testing(amount_x),
            balance::create_for_testing(amount_y), &mut versioned, &clock, &ctx
        );
        position::destroy_for_testing(position);
        let (x_out, y_out, receipt) = pool::flash(&mut pool, 0, 0, &mut versioned, &ctx);
        let (amount_x_debt, amount_y_debt) = pool::flash_receipt_debts(&receipt);
        pool::repay(&mut pool, receipt, balance::create_for_testing(100), balance::create_for_testing(200), &mut versioned, &ctx);
        assert!(
            pool::fee_growth_global_x(&pool) == (84 * (1u128 << 64) / 2000000000) &&
            pool::fee_growth_global_y(&pool) == (167 * (1u128 << 64) / 2000000000) &&
            pool::protocol_fee_x(&pool) == 16 && pool::protocol_fee_y(&pool) == 33,
            0
        );
        balance::destroy_for_testing(x_out);
        balance::destroy_for_testing(y_out);
        pool::destroy_for_testing(pool);

        clock::destroy_for_testing(clock);
        versioned::destroy_for_testing(versioned);
        flowx_clmm::admin_cap::destroy_for_testing(admin_cap);
    }
}