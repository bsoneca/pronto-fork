package machine

// Statecharts and lifecycle reducers: one row's field, its transitions and
// the SQL they become.

refuses: "a SQL call names a declared hatch": {
	program: _payment & _billingEntry
	says: ["calls undeclared SQL hatch: billing"]
}

refuses: "a SQL call names a SQL hatch": {
	program: _payment & _billingEntry & {app: capabilities: hatches: billing: {kind: "container", note: "billing"}}
	says: ["calls hatch billing, which is not SQL"]
}

admits: "a declared SQL hatch is called, and named among the machine's hatches": {
	program: _payment & _billingEntry & {
		app: capabilities: hatches: billing: {kind: "sql", files: ["services/database/migrations/020_billing.sql"], note: "the billing function owns the write"}
	}
	expect: {
		hatches: {value: program.code.state.machines.PaymentMachine.hatches, equals: ["billing"]}
		sql: {value: program.out[_machines].text, has: ["PERFORM bill(NEW.id)"]}
	}
}

admits: "state actions run on entry and in exit-transition-entry order": {
	program: _payment & {with: states: {
		pending: {
			entry: raise: {notify: "trace", payload: "initial"}
			exit: raise: {notify: "trace", payload: "exit"}
			on: pay: {target: "charging", actions: raise: {notify: "trace", payload: "transition"}}
		}
		charging: {
			invoke: {src: "charge", onDone: "settled", onError: _onError}
			entry: raise: {notify: "trace", payload: "entry"}
		}
		settled: type: "final"
		failed: on: retry: "pending"
	}}
	expect: sql: {
		value: program.out[_machines].text
		order: ["pg_notify('trace', 'initial')", "pg_notify('trace', 'exit')", "pg_notify('trace', 'transition')", "pg_notify('trace', 'entry')"]
	}
}

// Signals are raises and SQL calls are hatches, never relational effects.
for k, e in {notify: {notify: "payments", payload: "changed"}, stream: {stream: "payments"}, call: {call: "bill"}} {
	refuses: "a \(k) is no relational effect": {
		program: _payment & {app: state: machines: PaymentMachine: states: pending: entry: effect: e}
		says: ["pending.entry.effect.\(k): field not allowed"]
	}
}

admits: "an outcome raises each of its signals": {
	program: _payment & {with: states: {
		pending: on: pay: "charging"
		charging: invoke: {
			src: "charge"
			onDone: {target: "settled", actions: {raise: [{notify: "payments", payload: "done"}, {notify: "audit", payload: "paid"}]}}
			onError: _onError
		}
		settled: type: "final"
		failed: on: retry: "pending"
	}}
	expect: sql: {value: program.out[_machines].text, has: ["pg_notify('payments', 'done')", "pg_notify('audit', 'paid')"]}
}

for k, c in {
	missing: {extra: {}, says: "pipelines.authored.note: field is required but not present"}
	empty: {extra: note: "", says: #"pipelines.authored.note: invalid value "" (out of bound !="")"#}
} {
	refuses: "a raw pipeline with a \(k) note is refused": {
		program: _payment & {app: state: pipelines: authored: {raw: true, from: "Payment", to: "Payment", group: "authored"} & c.extra}
		says: [c.says]
	}
}

admits: "a raw pipeline with its rationale has unspecified delivery": {
	program: _payment & {app: state: pipelines: authored: {raw: true, from: "Payment", to: "Payment", group: "authored", note: "the authored sink decides delivery"}}
	expect: delivery: {value: program.code.state.pipelines.authored.delivery, equals: "unspecified"}
}

for event in ["insert", "update", "delete"] {
	refuses: "a statechart cannot also handle \(event), whose SQL it would discard": {
		program: _payment & {app: state: machines: PaymentMachine: on: (event): raise: {notify: "payments", payload: "TG_OP"}}
		says: ["machine PaymentMachine combines states and lifecycle handlers: declare separate machines"]
	}
}

admits: "mecha machine compiles statechart into PostgreSQL 010_machines.sql": {
	program: _challenge
	expect: sql: {
		value: program.out[_machines].text
		has: [
			#"ALTER TABLE "challenge" ADD CONSTRAINT "challenge_status_check" CHECK ("status" IN"#,
			"'pending'", "'accepted'", "'declined'", "'expired'",
			#"CREATE OR REPLACE FUNCTION "trg_challenge_status_machine"()"#,
			"new % must start in initial state % (got %)",
			"cannot transition from final state % on %",
			// A timeout arms the ticker rather than depending on another client write.
			"interval '60000 milliseconds'",
			"CREATE TABLE IF NOT EXISTS public.machine_timer_tick",
			"timer_delay = '60000'",
			#"INSERT INTO "audit_log" ("event") VALUES ('challenge_accepted') ON CONFLICT ("id") DO NOTHING;"#,
			#"CREATE TRIGGER "trg_challenge_status_machine""#,
		]
	}
}

admits: "a strict create emits a bare INSERT": {
	program: _challenge & {with: op: "create"}
	expect: sql: {
		value: program.out[_machines].text
		has: [#"INSERT INTO "audit_log" ("event") VALUES ('challenge_accepted');"#]
		lacks: ["ON CONFLICT"]
	}
}

refuses: "an op outside #RelationalOp is refused: the word is the terminal's, matched by spelling in emit.cue": {
	program: _challenge & {with: op: "insert"}
	// cue names the field and the word, so a fixture that fails elsewhere
	// does not pass as a refused op
	says: [#"effect.op: conflicting values "create" and "insert""#]
}

admits: "mecha machine compiles mutation lifecycle reducer with relational effects": {
	program: {
		with: {name: "test-reducer", reads: "expense"}
		app: state: {
			entities: Expense: {
				table:      "expense"
				durability: "server"
				fields: [
					{name: "id", type: "uuid", pk: true},
					{name: "amount", type: "decimal", precision: 18, scale: 2},
					{name: "bucket", type: "string"},
				]
			}
			machines: ExpenseReducer: {
				name:   "ExpenseReducer"
				entity: "Expense"
				on: insert: effect: {
					op:    "accumulate"
					table: "category_month_stat"
					key: ["bucket"]
					values: {bucket: {raw: "NEW.bucket"}, spent: {raw: "NEW.amount"}, expense_count: 1}
				}
			}
		}
	}
	expect: sql: {
		value: program.out[_machines].text
		has: [
			#"CREATE OR REPLACE FUNCTION "trg_expense_ExpenseReducer_reducer"()"#,
			#"INSERT INTO "category_month_stat" ("bucket", "spent", "expense_count") VALUES (NEW.bucket, NEW.amount, 1) ON CONFLICT ("bucket") DO UPDATE SET "spent" = "category_month_stat"."spent" + EXCLUDED."spent", "expense_count" = "category_month_stat"."expense_count" + EXCLUDED."expense_count";"#,
			#"CREATE TRIGGER "trg_expense_ExpenseReducer_reducer""#,
			#"AFTER INSERT OR UPDATE OR DELETE ON "expense""#,
		]
	}
}

admits: "mecha machine compiles update with where and upsert with updateValues": {
	program: {
		with: {name: "test-update", reads: "expense"}
		app: state: {
			entities: Expense: {
				table:      "expense"
				durability: "server"
				fields: [
					{name: "id", type: "uuid", pk: true},
					{name: "amount", type: "decimal", precision: 18, scale: 2},
					{name: "bucket", type: "string"},
					{name: "month", type: "string"},
				]
			}
			machines: ExpenseLedger: {
				name:   "ExpenseLedger"
				entity: "Expense"
				on: {
					insert: effect: {
						op:    "upsert"
						table: "month_stat"
						key: ["month"]
						values: {month: {raw: "NEW.month"}, spent: {raw: "NEW.amount"}, expense_count: 1}
						updateValues: {
							spent: {raw: #""month_stat"."spent" + EXCLUDED."spent""#}
							expense_count: {raw: #""month_stat"."expense_count" + EXCLUDED."expense_count""#}
						}
					}
					delete: effect: {
						op:    "update"
						table: "category_month_stat"
						where: {bucket: {raw: "OLD.bucket"}}
						values: {spent: {raw: "GREATEST(0, category_month_stat.spent - OLD.amount)"}}
					}
				}
			}
		}
	}
	expect: sql: {
		value: program.out[_machines].text
		has: [
			#"INSERT INTO "month_stat" ("month", "spent", "expense_count") VALUES (NEW.month, NEW.amount, 1) ON CONFLICT ("month") DO UPDATE SET "spent" = "month_stat"."spent" + EXCLUDED."spent", "expense_count" = "month_stat"."expense_count" + EXCLUDED."expense_count";"#,
			#"UPDATE "category_month_stat" SET "spent" = GREATEST(0, category_month_stat.spent - OLD.amount) WHERE "bucket" = OLD.bucket;"#,
		]
	}
}

admits: "a machine signals a duckstream pipeline": {
	program: _payment & {
		with: states: _finals & {
			pending: on: pay: {target: "charging", actions: [{raise: {stream: "payment_analytics", signal: "refresh"}}]}
			charging: invoke: {src: "charge", onDone: "settled", onError: "failed"}
		}
		app: state: duckstreams: payment_analytics: {
			name: "payment_analytics"
			sql:  "SELECT count(*) AS settled FROM payment WHERE status = 'settled'"
			sources: ["payment"]
			sink: "payment_metrics"
		}
	}
	expect: {
		sql: {value: program.out[_machines].text, has: ["PERFORM pg_notify('duckstream_payment_analytics', jsonb_build_object('signal', 'refresh', 'table', TG_TABLE_NAME, 'id', NEW.id::text)::text);"]}
		pipeline: {value: program.out["pipelines/duckstream/payment_analytics.sql"].text, has: ["SELECT count(*) AS settled FROM payment WHERE status = 'settled'"]}
	}
}

refuses: "a machine referencing an undeclared duckstream is refused at compile time": {
	program: _payment & {with: states: _finals & {
		pending: on: pay: {target: "charging", actions: [{raise: {stream: "undeclared_stream"}}]}
		charging: invoke: {src: "charge", onDone: "settled", onError: "failed"}
	}}
	says: ["machine PaymentMachine references undeclared duckstream: undeclared_stream"]
}

refuses: "a machine referencing NEW in delete action is refused at compile time": {
	program: {
		with: name: "test-app"
		app: state: {
			entities: Order: {
				table:      "orders"
				durability: "offline"
				fields: [{name: "id", type: "uuid", pk: true}]
			}
			machines: OrderLifecycle: {
				name:   "OrderLifecycle"
				entity: "Order"
				on: delete: [{raise: {stream: "cleanup_order", key: "NEW.id"}}]
			}
			duckstreams: cleanup_order: {
				name: "cleanup_order"
				sql:  "SELECT 1"
				sources: ["orders"]
				sink: "order_metrics"
			}
		}
	}
	says: ["machine OrderLifecycle references NEW in delete action", "NEW.id"]
}

admits: "mecha machine compiles function calls, combined where/rawWhere, and prefixed stream keys": {
	program: {
		with: name: "test-composite"
		app: {
			state: {
				entities: Item: {
					table:      "item"
					durability: "server"
					fields: [
						{name: "id", type: "uuid", pk: true},
						{name: "month", type: "string"},
						{name: "amount", type: "decimal", precision: 12, scale: 2},
					]
				}
				machines: ItemMachine: {
					name:   "ItemMachine"
					entity: "item"
					timing: "AFTER"
					on: insert: [
						{hatch: {name: "locking", call: "pg_advisory_xact_lock", args: [{raw: "hashtext('test_lock')::bigint"}]}},
						{effect: {
							op:    "update"
							table: "item_summary"
							where: {month: {raw: "NEW.month"}}
							rawWhere: #""active" = true"#
							values: {spent: {raw: "item_summary.spent + NEW.amount"}}
						}},
						{raise: {stream: "item_stream", key: "NEW.month"}},
					]
				}
				duckstreams: item_stream: {
					name: "item_stream"
					sql:  "SELECT count(*) FROM item"
					sources: ["item"]
					sink: "item_stat"
				}
			}
			capabilities: hatches: locking: {kind: "sql", files: ["services/database/migrations/020_locking.sql"], note: "serializes writers to the summary"}
		}
	}
	expect: sql: {
		value: program.out[_machines].text
		has: [
			"PERFORM pg_advisory_xact_lock(hashtext('test_lock')::bigint);",
			#"UPDATE "item_summary" SET "spent" = item_summary.spent + NEW.amount WHERE "month" = NEW.month AND "active" = true;"#,
			"PERFORM pg_notify('duckstream_item_stream', jsonb_build_object('signal', 'refresh', 'table', TG_TABLE_NAME, 'id', NEW.month::text)::text);",
		]
	}
}

admits: "Mecha actions qualify private tables and order locks before writes": {
	program: _payment & {app: state: machines: PaymentMachine: states: pending: entry: {
		lock: {schema: "private", table: "account", key: "id", values: [{raw: "NEW.id"}]}
		effect: {op: "update", schema: "private", table: "account", values: {active: true}, rawWhere: "id = NEW.id"}
	}}
	expect: sql: {
		value: program.out[_machines].text
		order: [
			#"FROM "private"."account" WHERE "id" IN (NEW.id) ORDER BY "id" FOR UPDATE;"#,
			#"UPDATE "private"."account" SET "active" = true WHERE id = NEW.id;"#,
		]
	}
}

// The entity is the machine's fault, not its invoke's: a machine that invokes
// nothing names it too, and emit.cue would index an empty list for its table.
refuses: "a machine naming an undeclared entity is refused": {
	program: _payment & {with: entity: "Invoice"}
	says: ["machine PaymentMachine names undeclared entity: Invoice"]
}

refuses: "a machine naming an undeclared entity is refused though it invokes nothing": {
	program: _payment & _plain & {with: entity: "Invoice"}
	says: ["machine PaymentMachine names undeclared entity: Invoice"]
}
