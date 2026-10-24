package machine

import "strings"

// External effects: the ledger claim, the airlock's manifest, its sinks and
// the declarations each refuses.

admits: "entering an invoking state claims the ledger and enqueues in the transition's commit": {
	program: _payment
	expect: {
		sql: {
			value: program.out[_machines].text
			has: [
				#"INSERT INTO "airlock"."external_effect_ledger" ("key", "effect", "row", "input")"#,
				#"VALUES ('charge:' || NEW."id"::text, 'charge', jsonb_build_object('id', NEW."id"), jsonb_build_object('amount', NEW."total", 'currency', 'BRL'))"#,
				// A second claim of a performed key is refused, not skipped.
				#"IF NOT FOUND THEN\#n          RAISE EXCEPTION 'external effect % was already performed: entering charging again needs a new key', 'charge:' || NEW."id"::text USING ERRCODE = 'unique_violation';"#,
				#"PERFORM graphile_worker.add_job('external_effect', json_build_object('key', 'charge:' || NEW."id"::text), job_key => 'charge:' || NEW."id"::text, max_attempts => 30);"#,
				// The ticker's one-shot row re-armed, so a cluster asleep is woken
				// for the job; it writes only a row not yet armed and waits on no
				// lock, so claims never queue on the one row (emit.cue).
				#"UPDATE "public"."schedule" SET "due_at" = date_trunc('milliseconds', clock_timestamp()), "last_tick_at" = NULL\#n         WHERE "name" = 'airlock' AND "last_tick_at" IS NOT NULL\#n           AND "name" IN (SELECT "name" FROM "public"."schedule" WHERE "name" = 'airlock' FOR UPDATE SKIP LOCKED);"#,
				// A key is a field's text, spelled the same in every session.
				"SET search_path = public, pg_catalog\nSET TimeZone = 'UTC'\nSET DateStyle = 'ISO, YMD' AS $$",
				// Leaving is admitted only by the ledger's recorded outcome, keyed on the old row.
				#"SELECT l."outcome" INTO outcome FROM "airlock"."external_effect_ledger" l WHERE l."key" = 'charge:' || OLD."id"::text;"#,
				#"NEW."failure" := outcome->>'kind';"#,
				"DECLARE\n  outcome jsonb;",
			]
		}
		// The ledger is mecha's (services/airlock/airlock.sql), placed by the cluster.
		ledger: {value: [for k, _ in program.out if strings.Contains(k, "migrations/015_") {k}], equals: []}
	}
}

admits: "the airlock is handed each effect's state, outcome targets, sink and handler": {
	program: _payment & {with: sink: {origin: _origin, idempotent: false}}
	expect: {
		manifest: {
			value: program.out[_effects].data
			equals: effects: charge: {
				table:   "payment"
				field:   "status"
				state:   "charging"
				onDone:  "settled"
				onError: "failed"
				row: ["id"]
				idempotent: false
				reentry:    "reconcile"
				attempts:   5
				handler:    "effects/charge.js"
			}
		}
		binding: {
			value: program.out["services/airlock/dapr/charge.yaml"].data
			equals: {
				apiVersion: "dapr.io/v1alpha1"
				kind:       "Component"
				metadata: name: "charge"
				spec: {
					type:    "bindings.http"
					version: "v1"
					metadata: [{name: "url", value: _origin}, {name: "errorIfNot2XX", value: "false"}]
				}
			}
		}
		handler: {value: program.out["effects/charge.js"], equals: {format: "jessie", src: "effects/charge.js"}}
	}
}

admits: "secrets are declared by their environment variables, reaching the manifest": {
	program: _payment & {app: state: effects: charge: secrets: ["PAY_SIGNING_KEY"]}
	expect: secrets: {value: program.out[_effects].data.effects.charge.secrets, equals: ["PAY_SIGNING_KEY"]}
}

refuses: "a secret is an environment variable's name, never a value": {
	program: _payment & {app: state: effects: charge: secrets: ["pay-key"]}
	says: [#"effects.charge.secrets.0: invalid value "pay-key""#]
}

admits: "a sink's credential is a header the airlock adds from a declared secret, required of the environment and handed to no handler": {
	program: _payment & {
		with: sink: _credentialed
		app: state: effects: charge: secrets: ["ACQUIRER_WEBHOOK_KEY"]
	}
	let manifest = program.out[_effects].data.effects.charge
	expect: {
		credential: {value: manifest.credential, equals: {header: "Authorization", scheme: "Bearer", secret: "ACQUIRER_KEY"}}
		secrets: {value: manifest.secrets, equals: ["ACQUIRER_WEBHOOK_KEY"]}
		environment: {value: program._cluster.surface.targets.airlock.compose.environment.ACQUIRER_KEY, equals: "${ACQUIRER_KEY:?ACQUIRER_KEY is required: an effect declares it}"}
	}
}

_credentialed: {origin: _origin, idempotent: true, credential: {scheme: "Bearer", secret: "ACQUIRER_KEY"}}

refuses: "a credential's secret is an environment variable's name": {
	program: _payment & {with: sink: {origin: _origin, idempotent: true, credential: {scheme: "Bearer", secret: "acquirer-key"}}}
	// cue folds an origin sink's own reason into the sink's empty
	// disjunction and prints the bridge sink's, which takes no credential.
	says: ["effects.charge.sink.credential: field not allowed"]
}

// A header daprd forwards starts uppercase, and is none the host or HTTP sets.
for h in ["x-api-key", "Idempotency-Key", "content-type", "Host"] {
	refuses: "a credential cannot ride in header \(h)": {
		program: _payment & {with: sink: {origin: _origin, idempotent: true, credential: {header: h, secret: "ACQUIRER_KEY"}}}
		// cue folds an origin sink's own reason into the sink's empty
		// disjunction and prints the bridge sink's, which takes no credential.
		says: ["effects.charge.sink.credential: field not allowed"]
	}
}

refuses: "a credential is the airlock's alone, never also the handler's": {
	program: _payment & {
		with: sink: _credentialed
		app: state: effects: charge: secrets: ["ACQUIRER_KEY"]
	}
	says: ["effect charge lists its credential's ACQUIRER_KEY among the handler's secrets"]
}

refuses: "a credential is no variable the cluster's own services read": {
	program: _payment & {with: sink: {origin: _origin, idempotent: true, credential: {scheme: "Bearer", secret: "SERVICE_JWT"}}}
	// cue folds an origin sink's own reason into the sink's empty
	// disjunction and prints the bridge sink's, which takes no credential.
	says: ["effects.charge.sink.credential: field not allowed"]
}

refuses: "a handler's secret is no variable the cluster's own services read": {
	program: _payment & {app: state: effects: charge: secrets: ["POSTGRES_PASSWORD"]}
	says: [#"effects.charge.secrets.0: invalid value "POSTGRES_PASSWORD""#]
}

refuses: "a bridge takes no credential: past it nothing is the platform's to carry": {
	program: _payment & {
		with: sink: {bridge: "mail", idempotent: false, credential: secret: "K"}
		app: state: {bridges: mail: _mail, effects: charge: reentry: "unknown"}
	}
	says: ["effects.charge.sink.credential: field not allowed"]
}

admits: "the level is derived: the entity's from its durability, the machine's from its invoke": {
	program: _payment
	expect: levels: {
		value: {entity: program.code.state.entities.Payment.level, machine: program.code.state.machines.PaymentMachine.level}
		equals: {entity: "replicated", machine: "external"}
	}
}

refuses: "an authored level is refused: it is the durability's to say": {
	program: _payment & {app: state: entities: Payment: level: "ephemeral"}
	says: [#"entities.Payment.level: conflicting values "replicated" and "ephemeral""#]
}

for n, t in {Wake: "airlock_wake", Sched: "schedule"} {
	refuses: "an entity cannot take the airlock wake's table \(t)": {
		program: _payment & {app: state: entities: (n): {table: t, durability: "server", fields: [{name: "id", type: "uuid", pk: true}]}}
		says: ["entity \(n) takes table \(t), which the airlock's wake keeps"]
	}
}

refuses: "a schedule cannot take the airlock wake's name": {
	program: _payment & {app: state: schedules: airlock: {cron: "0 3 * * *", emits: {entity: "Payment", values: status: "pending"}}}
	says: ["schedule airlock is the airlock's own wake"]
}

// No auth plane, yet the service role, its bypass and its grants: the
// ticker's writes land as it.
admits: "an effect's cluster keeps the service role the ticker writes as": {
	program: _payment
	expect: {
		roles: {
			value: program.out["services/database/migrations/001_roles.sql"].text
			has: ["CREATE ROLE service NOLOGIN;", "ALTER ROLE service BYPASSRLS;"]
			lacks: ["app_user"]
		}
		grants: {value: program.out["services/database/migrations/002_grants.sql"].text, has: ["ON ALL TABLES IN SCHEMA public TO anon, service;"]}
	}
}

admits: "the roles migration leaves electric's password to the deployment": {
	why:     "The schema states electric's attributes and never its password: on Kubernetes the operator sets the password from a secret, and a roles migration that set one would overwrite it whenever it ran."
	program: _payment
	let text = program.out["services/database/migrations/001_roles.sql"].text
	expect: {
		roles: {value: text, has: ["ALTER ROLE electric BYPASSRLS REPLICATION LOGIN;"]}
		anyCase: {value: strings.ToUpper(text), lacks: ["PASSWORD"]}
	}
}

admits: "an effect reached through a bridge gets the bridge's in-cluster endpoint": {
	program: _payment & {
		with: sink: {bridge: "mail", idempotent: false}
		app: state: {bridges: mail: _mail, effects: charge: reentry: "unknown"}
	}
	expect: {
		url: {value: program.out["services/airlock/dapr/charge.yaml"].data.spec.metadata[0], equals: {name: "url", value: "http://bridge-mail:8080"}}
		reentry: {value: program.out[_effects].data.effects.charge.reentry, equals: "unknown"}
	}
}

refuses: "a bridged effect is not idempotent: past a bridge nothing is the platform's to promise": {
	program: _payment & {with: sink: {bridge: "mail", idempotent: true}, app: state: bridges: mail: _mail}
	says: ["past a bridge nothing is the platform's to promise"]
}

refuses: "a bridged effect states what a repeat costs, since a bridge answers no query": {
	program: _payment & {with: sink: {bridge: "mail", idempotent: false}, app: state: bridges: mail: _mail}
	says: ["a bridge answers no query"]
}

admits: "a bridged effect that may repeat says so": {
	program: _payment & {
		with: sink: {bridge: "mail", idempotent: false}
		app: state: {bridges: mail: _mail, effects: charge: reentry: "repeat"}
	}
	expect: reentry: {value: program.out[_effects].data.effects.charge.reentry, equals: "repeat"}
}

refuses: "an effect reaching an undeclared bridge is refused": {
	program: _payment & {with: sink: {bridge: "smtp", idempotent: false}}
	says: ["effect charge reaches undeclared bridge: smtp"]
}

refuses: "a bridge no effect reaches is refused": {
	program: _payment & {app: state: bridges: mail: _mail}
	says: ["bridge mail is reached by no effect"]
}

refuses: "a bridge's server is no local address": {
	program: _payment & {
		with: sink: {bridge: "mail", idempotent: false}
		app: state: {bridges: mail: {kind: "mail", server: "localhost:25", domain: "airlock.example"}, effects: charge: reentry: "unknown"}
	}
	says: [#"bridges.mail.server: invalid value "localhost:25""#]
}

admits: "an effect declares its handler's endowments, as an omnishell module declares Intl": {
	program: _payment & {app: state: effects: charge: endowments: ["Crypto", "TextEncoder"]}
	expect: endowments: {value: program.out[_effects].data.effects.charge.endowments, equals: ["Crypto", "TextEncoder"]}
}

refuses: "an effect's handler is endowed with no Intl": {
	program: _payment & {app: state: effects: charge: endowments: ["Intl"]}
	says: ["effects.charge.endowments.0: conflicting values", #"and "Intl""#]
}

refuses: "an effect is invoked by no more than one state": {
	program: _payment & {with: states: {
		pending: on: pay: "charging"
		charging: invoke: {src: "charge", onDone: "settled", onError: "again"}
		again: invoke: {src: "charge", onDone: "settled", onError: "failed"}
		settled: type: "final"
		failed: type:  "final"
	}}
	says: ["effect charge is invoked by 2 states: exactly one invokes it"]
}

refuses: "an effect is invoked by at least one state": {
	program: _payment & {with: states: {
		pending: on: pay: "settled"
		settled: type: "final"
	}}
	says: ["effect charge is invoked by no state: its entity is its invoking machine's, so it has none"]
}

refuses: "an effect's name is a DNS label, as its Dapr endpoint's must be": {
	program: _payment & {with: effect: "charge_card"}
	says: [#"effects.charge_card.name: invalid value "charge_card""#]
}

admits: "an initial state that invokes claims on insert": {
	program: _payment & {with: {
		initial: "charging"
		states: _finals & {charging: invoke: {src: "charge", onDone: "settled", onError: "failed"}}
	}}
	let sql = program.out[_machines].text
	expect: insertPath: {
		value: strings.Split(strings.Split(sql, "IF TG_OP = 'INSERT' THEN")[1], "IF TG_OP = 'UPDATE' THEN\n")[0]
		has: [#"INSERT INTO "airlock"."external_effect_ledger""#]
	}
}

admits: "a key of several fields is JSON-encoded, so a ':' in a value makes no two instances one, and the queue holds more than the attempts": {
	program: _payment & {app: state: effects: charge: {key: ["id", "failure"], attempts: 2}}
	expect: sql: {value: program.out[_machines].text, has: [#"'charge:' || jsonb_build_array(NEW."id"::text, NEW."failure"::text)::text"#, "max_attempts => 27"]}
}

// An invoking state is left only by its outcome; a program whose outcome could
// never be delivered would hold the row there while the airlock retried.
for k, c in {
	"a final invoking state": {
		charging: {type: "final", invoke: {src: "charge", onDone: "settled", onError: "failed"}}
		says: "is final: no outcome could leave it"
	}
	"an outcome targeting no state": {
		charging: invoke: {src: "charge", onDone: "setled", onError: "failed"}
		says: "an outcome target that is no state: setled"
	}
	"an outcome targeting its own state": {
		charging: invoke: {src: "charge", onDone: "settled", onError: "charging"}
		says: "an outcome targeting itself"
	}
	"outcomes sharing a target and carrying actions": {
		charging: invoke: {src: "charge", onDone: "failed", onError: {target: "failed", actions: [{assign: {failure: "x"}}]}}
		says: "share target failed and carry actions"
	}
	"an outcome whose actions reject": {
		charging: invoke: {src: "charge", onDone: "settled", onError: {target: "failed", actions: [{reject: "no"}]}}
		says: "an outcome's actions reject"
	}
} {
	refuses: "\(k) is refused, its outcome never delivered": {
		program: _payment & {with: states: _toCharging & {charging: c.charging}}
		says: [c.says]
	}
}

for k, action in {"charging's exit": {charging: exit: reject: "no"}, "settled's entry": {settled: entry: reject: "no"}} {
	refuses: "an outcome is refused where \(k) rejects": {
		program: _payment & {app: state: machines: PaymentMachine: states: action}
		says: ["an outcome's entry or exit actions reject"]
	}
}

admits: "an outcome with one target for both arrows and no actions is a plain join": {
	program: _payment & {with: states: _toCharging & {charging: invoke: {src: "charge", onDone: "failed", onError: "failed"}}}
	expect: sql: value: program.out[_machines].text
}

refuses: "an input reads a field the entity has": {
	program: _payment & {app: state: effects: charge: input: amt: "NEW.totl"}
	says: ["input amt reads NEW.totl, which is not a field of Payment"]
}

admits: "an input's name is quoted": {
	program: _payment & {app: state: effects: charge: input: "it's": "NEW.total"}
	expect: sql: {value: program.out[_machines].text, has: [#"'it''s', NEW."total""#]}
}

admits: "a row in an invoking state keeps its key and is not deleted until its outcome": {
	program: _payment & {app: state: effects: charge: key: ["id", "failure"]}
	expect: sql: {
		value: program.out[_machines].text
		has: [
			#"IF TG_OP = 'DELETE' THEN\#n    IF OLD."status" IN ('charging') THEN\#n      RAISE EXCEPTION '% in % awaits an outcome and is not deleted'"#,
			#"IF TG_OP = 'UPDATE' AND OLD."status" = 'charging' AND (OLD."failure" IS DISTINCT FROM NEW."failure" OR OLD."id" IS DISTINCT FROM NEW."id") THEN\#n    RAISE EXCEPTION '% in charging keeps its key until the outcome of %'"#,
			#"BEFORE INSERT OR UPDATE OR DELETE ON "payment""#,
		]
	}
}

admits: "a machine with no invoke keeps its trigger as it was": {
	program: _payment & _plain
	expect: sql: {
		value: program.out[_machines].text
		has: [#"BEFORE INSERT OR UPDATE ON "payment""#]
		lacks: ["TG_OP = 'DELETE'"]
	}
}

refuses: "an invoke naming no declared effect is refused": {
	program: _payment & {with: src: "refund"}
	says: ["machine PaymentMachine state charging invokes undeclared effect: refund"]
}

refuses: "an invoking state with any exit but its outcome is refused": {
	program: _payment & {with: states: _finals & {
		pending: on: pay: "charging"
		charging: {
			invoke: {src: "charge", onDone: "settled", onError: "failed"}
			on: cancel: "failed"
		}
	}}
	says: ["machine PaymentMachine state charging invokes charge and declares on or after: only the effect's outcome leaves it"]
}

refuses: "an effect's entity is the invoking machine's, and an authored one is a field the effect lacks": {
	why: "The effect's entity is read off the invoking machine (#App's _effectEntityNames), so a declaration has no second place to state it: the closed #ExternalEffect refuses the field, agreeing or not."
	program: _payment & {app: state: effects: charge: entity: "Payment"}
	says: ["app.state.effects.charge.entity: field not allowed"]
}

refuses: "an effect invoked by machines of two entities is refused": {
	why: "One effect reads NEW and keys on fields of one row; two machines over two entities would hand it two shapes under one ledger prefix."
	program: _payment & {app: state: {
		entities: Order: {table: "orders", durability: "server", fields: [{name: "id", type: "uuid", pk: true}, {name: "status", type: "string"}]}
		machines: OrderMachine: {
			name:    "OrderMachine"
			entity:  "Order"
			field:   "status"
			initial: "open"
			states: {
				open: on: pay: "paying"
				paying: invoke: {src: "charge", onDone: "paid", onError: "open"}
				paid: type: "final"
			}
		}
	}}
	says: ["effect charge is invoked by machines of 2 entities (Order, Payment): its NEW reads and its key need one row"]
}

refuses: "an effect of an entity the cluster does not hold is refused": {
	program: _payment & {with: durability: "tab"}
	says: ["effect charge is of Payment, whose rows do not live in the cluster"]
}

refuses: "an effect keyed on a field the entity lacks is refused": {
	program: _payment & {app: state: effects: charge: key: ["intent"]}
	says: ["effect charge keys on intent, which is not a field of Payment"]
}

refuses: "reentry is declared only for a sink that is not idempotent": {
	program: _payment & {app: state: effects: charge: reentry: "unknown"}
	says: ["reentry", "field not allowed"]
}

refuses: "reentry is a word: the reason a duplicate is acceptable is the effect's note": {
	program: _payment & {
		with: sink: {origin: _origin, idempotent: false}
		app: state: effects: charge: reentry: repeat: "a second mail is a nuisance"
	}
	says: [#"effects.charge.reentry: conflicting values {repeat:"a second mail is a nuisance"} and "repeat""#]
}

admits: "a sink that is not idempotent needs no reentry of its own": {
	program: _payment & {with: sink: {origin: _origin, idempotent: false}}
	expect: sql: value: program.out[_machines].text
}

// Idempotency and the cost of a repeat are claims about a peer the compiler
// cannot check, so every effect carries the judgment in prose.
refuses: "an effect without a note is refused": {
	program: _payment & {with: note: null}
	says: [#"effects.charge.note: incomplete value !="""#]
}

refuses: "an effect with an empty note is refused": {
	why: "An empty note is the field present and the judgment absent: `repeat` with nothing said would admit a duplicate for no stated reason."
	program: _payment & {with: note: ""}
	says: [#"app.state.effects.charge.note: invalid value "" (out of bound !="")"#]
}

admits: "an effect with a note emits its manifest": {
	program: _payment
	expect: manifest: value: program.out[_effects] & {...}
}

// The airlock's daprd sits on the cluster's own network: an origin naming a
// service there by its single label, or any address, would be a door inward,
// and userinfo would put a credential where the binding's secrets belong.
for o in [
	"http://api.acquirer.example", "https://api.acquirer.example/v1/charges", "https://database", "https://database:5432",
	"https://10.0.0.7", "https://169.254.169.254", "https://[::1]", "https://user:pw@api.acquirer.example",
] {
	refuses: "a sink origin is an https origin naming a DNS host, and nothing more: \(o)": {
		program: _payment & {with: sink: {origin: o, idempotent: true}}
		says: [#"effects.charge.sink.origin: invalid value "\#(o)""#]
	}
}
