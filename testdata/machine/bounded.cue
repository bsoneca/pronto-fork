package machine

// Bounded Mecha machines: the XState a Postgres trigger can run, and the
// spawn and send a statechart reaches them by.

refuses: "a bounded machine's SQL call names a declared hatch": {
	program: _payment & _bounded & {app: state: hybrids: bounded: machine: setup: actions: bill: [{hatch: {name: "billing", call: "bill"}}]}
	says: ["calls undeclared SQL hatch: billing"]
}

admits: "a bounded machine calls a declared SQL hatch": {
	program: _payment & _bounded & _billingSql & {app: state: hybrids: bounded: machine: setup: actions: bill: [{hatch: {name: "billing", call: "bill"}}]}
	expect: hybrids: value: program.code.state.hybrids
}

_billingSql: app: capabilities: hatches: billing: {kind: "sql", files: ["billing.sql"], note: "billing operation"}

for k, c in {
	assign: {action: assign: {phase: "ready"}, says: ["explicit error (_|_ literal) in source", "mecha-reducer.cue"]}
	lock: {action: lock: {table: "account", key: "id", values: [1]}, says: ["explicit error (_|_ literal) in source", "mecha-reducer.cue"]}
	raise: {action: raise: {stream: "scores"}, says: ["reducer.states.ready.on.run.actions.0.raise.stream: field not allowed"]}
} {
	refuses: "a bounded machine refuses the trigger-only \(k)": {
		program: _payment & _bounded & _billingSql & {app: state: hybrids: bounded: machine: setup: actions: bill: [c.action]}
		says: c.says
	}
}

// An event's transition list compiled to an unguarded no-op, and an invoke
// was dropped: both read as valid machines doing something else.
for k, c in {
	"a guarded transition list": {ready: on: run: [{target: "done", guard: "mayRun"}, {target: "ready"}], says: "an event names one transition"}
	"an empty transition list": {ready: on: run: [], says: "an event names one transition"}
	"an invoke": {ready: {invoke: {src: "child"}, on: run: "done"}, says: "a Mecha machine invokes nothing"}
} {
	refuses: "a Mecha machine refuses \(k) instead of misreading it": {
		program: _payment & _xstate & {app: state: hybrids: bounded: machine: config: states: ready: c.ready}
		says: [c.says]
	}
}

admits: "a state's event listed as one transition is admitted": {
	program: _payment & _xstate & {app: state: hybrids: bounded: machine: config: states: ready: on: run: [{target: "done"}]}
	expect: hybrids: value: program.code.state.hybrids
}

refuses: "a state cannot take an event the machine takes in every state": {
	why: "XState takes the machine's transition when the state's own guard refuses; a state that takes the machine's event would refuse it here instead."
	program: _payment & _xstate & {app: state: hybrids: bounded: machine: config: {
		on: run: "done"
		states: ready: on: run: {guard: "mayRun", target: "done"}
	}}
	says: ["the machine takes run in every state"]
}

admits: "a machine's own transition taken in every state is admitted": {
	program: _payment & _xstate & {app: state: hybrids: bounded: machine: config: {states: ready: {}, on: run: "done"}}
	expect: hybrids: value: program.code.state.hybrids
}

refuses: "a machine's own transitions are held to the rule a state's are": {
	why: "A list of two normalized to a transition that did nothing."
	program: _payment & _xstate & {app: state: hybrids: bounded: machine: config: {
		on: run: [{target: "done", guard: "mayRun"}, {target: "ready"}]
		states: ready: {}
	}}
	says: ["bounded.on.run: an event names one transition"]
}

admits: "native Mecha spawn and send resolve declared bounded targets": {
	program: _payment & _spawning
	expect: sql: {value: program.out[_machines].text, has: ["PERFORM hybrid_child.spawn(NEW.id,", "PERFORM hybrid_child.deliver(NEW.id,"]}
}

for k, c in {
	"an undeclared target": {change: #machine: "missing", says: "undeclared Mecha operation target"}
	"a target with no initializer": {change: #initialize: null, says: "Mecha spawn requires an initializer"}
	"an undeclared event": {change: #event: "missing", says: "undeclared Mecha delivery event"}
	"an omnishell event": {change: #tier: "omnishell", says: "delivery requires a Mecha event"}
} {
	refuses: "native Mecha spawn and send refuse \(k)": {
		program: _payment & _spawning & c.change
		says: [c.says]
	}
}
