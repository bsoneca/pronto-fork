package machine

// One Payment machine whose `charging` state invokes `charge`. A struct a
// case replaces is chosen by a guard, not a default: a default struct unifies
// with an override it should yield to.
_payment: {
	with: {
		name:       "test-effects"
		reads:      "payment"
		entity:     *"Payment" | string
		durability: *"server" | string
		initial:    *"pending" | string
		// the effect's name, null for none declared
		effect: *"charge" | string | null
		src:    *effect | string
		note:   *"the acquirer deduplicates on Idempotency-Key" | string | null
		states?: {...}
		sink?: {...}
	}
	app: state: {
		entities: Payment: {
			table:      "payment"
			durability: with.durability
			fields: [
				{name: "id", type: "uuid", pk: true},
				{name: "status", type: "string"},
				{name: "total", type: "decimal", precision: 12, scale: 2},
				{name: "failure", type: "string"},
			]
		}
		machines: PaymentMachine: {
			name:    "PaymentMachine"
			entity:  with.entity
			field:   "status"
			initial: with.initial
			states: [if with.states != _|_ {with.states}, {
				pending: on: pay: "charging"
				charging: invoke: {src: with.src, onDone: "settled", onError: _onError}
				settled: type: "final"
				failed: on: retry: "pending"
			}][0]
		}
		effects: {
			if with.effect != null {
				(with.effect): {
					input: {amount: "NEW.total", currency: "BRL"}
					sink: [if with.sink != _|_ {with.sink}, {origin: _origin, idempotent: true}][0]
					if with.note != null {note: with.note}
				}
			}
		}
	}
}

_onError: {target: "failed", actions: [{assign: {failure: {raw: "outcome->>'kind'"}}}]}

// Shared parts the cases compose onto _payment.

_billingEntry: app: state: machines: PaymentMachine: states: pending: entry: hatch: {name: "billing", call: "bill", args: [{raw: "NEW.id"}]}

_mail: {kind: "mail", server: "smtp.mail.example:587", domain: "airlock.example"}

// The outcomes of a charging state the case states.
_finals: {
	settled: type: "final"
	failed: type:  "final"
}
_toCharging: _finals & {pending: on: pay: "charging"}

_plain: with: {
	effect: null
	states: {
		pending: on: pay: "settled"
		settled: type: "final"
	}
}

// A bounded Mecha machine whose `run` performs `bill`, its actions the case's.
_bounded: app: state: hybrids: bounded: {rules: "bounded.js", machine: {
	config: {id: "bounded", initial: "ready", states: ready: on: run: {actions: "bill"}}
	setup: {
		version: 1
		types: {
			context: {type: "object", fields: {}}
			view: {type: "object", fields: {}}
			events: run: {tier: "mecha", payload: {type: "object", fields: {}}}
		}
	}
}}

// A bounded machine whose `ready` state and root transitions are the case's.
_xstate: app: state: hybrids: bounded: {rules: "bounded.js", machine: {
	config: {id: "bounded", initial: "ready", states: done: type: "final"}
	setup: {
		version: 1
		types: {
			context: {type: "object", fields: {}}
			view: {type: "object", fields: {}}
			events: run: {tier: "omnishell", payload: {type: "object", fields: {}}}
		}
	}
}}

// Payment's pending spawns a bounded child and sends it `tick`.
_spawning: {
	#machine:    *"child" | string
	#initialize: *"initial" | null
	#event:      *"tick" | string
	#tier:       *"mecha" | string
	app: state: {
		hybrids: child: {rules: "child.js", machine: {
			config: {id: "child", initial: "ready", states: ready: on: tick: {}}
			setup: {
				version: 1
				if #initialize != null {initialize: #initialize}
				types: {
					context: {type: "object", fields: {}}
					input: {type: "object", fields: {}}
					view: {type: "object", fields: {}}
					events: tick: {tier: #tier, payload: {type: "object", fields: {}}}
				}
			}
		}}
		machines: PaymentMachine: states: pending: entry: [
			{spawn: {machine: #machine, id: {raw: "NEW.id"}, input: {}, members: owner: {raw: "NEW.id"}}},
			{send: {machine: #machine, id: {raw: "NEW.id"}, event: #event, payload: {}}},
		]
	}
}
