package machine

// A Challenge statechart whose `accept` performs one relational effect of
// `op` on audit_log.
_challenge: {
	with: {
		name:  "test-machine"
		reads: "challenge"
		op:    *"ensure" | string
		// merged into the status field
		status: {...}
		// the fields after status
		tail?: [...]
	}
	app: state: {
		entities: Challenge: {
			table:      "challenge"
			durability: "server"
			fields: [
				{name: "id", type: "uuid", pk: true},
				{name: "status", type: "string"} & with.status,
				for f in [if with.tail != _|_ {with.tail}, [{name: "created_at", type: "timestamp"}]][0] {f},
			]
		}
		machines: ChallengeMachine: {
			name:    "ChallengeMachine"
			entity:  "challenge"
			field:   "status"
			initial: "pending"
			states: {
				pending: {
					after: "60000": "expired"
					on: {
						accept: {
							target: "accepted"
							actions: [{effect: {op: with.op, table: "audit_log", values: {event: "challenge_accepted"}}}]
						}
						decline: "declined"
					}
				}
				accepted: type: "final"
				declined: type: "final"
				expired: type:  "final"
			}
		}
	}
}
