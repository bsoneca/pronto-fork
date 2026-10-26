// The programs mecha-machine.test.ts compiles, and its cases. A case's
// program is data, a fixture and what the case changes, until the runner
// unifies _program onto it: a refused value cannot sit in a package cue
// evaluates, and cue evaluates every value of the package it loads, so here
// nothing compiles and each case compiles in a process of its own.
package machine

import pronto "github.com/bonisoft3/pronto"

admits: [string]:  #Admit
refuses: [string]: #Refuse

// A program cue admits, and what its compilation holds. The runner compares
// each expectation, so a miss names the string it lacked.
#Admit: {
	why?: string
	program: {...}
	expect: [string]: #Expect
}

#Expect: {
	value!:  _
	equals?: _
	has?: [...string]
	lacks?: [...string]
	// each present, and after the one before
	order?: [...string]
}

// A program cue refuses, and what the refusal says, so a program failing
// elsewhere passes for no refusal.
#Refuse: {
	why?: string
	program: {...}
	says: [string, ...string]
}

// The compiler: one app compiled whole. `with` holds what a fixture lets a
// case swap rather than add; what a case adds it unifies onto `app`.
_program: {
	with: {
		name:   string
		reads?: string
	}
	app: pronto.#App & {
		meta: {
			name:        with.name
			description: "test"
			ir: sha256: ""
			targets: []
			clocks: []
			decisions: {}
			tests: {}
		}
		capabilities: {hatches: {}, vendored: {}}
		surface: {
			screens: {
				if with.reads != _|_ {
					board: {
						title:  "Board"
						route:  "/"
						markup: "<main></main>"
						reads: [{table: with.reads, kind: "live", nested: false, lists: [], route: "whole", clauses: [], embeds: [], orders: []}]
						forms: []
						states: []
					}
				}
			}
			handlers: {}
			design: {}
			flows: {}
		}
	}
	// What a case reads of the compiled app: a field its own data lacks, so
	// the read waits for the runner rather than failing on a field the app
	// derives.
	code: app
	_terminal: (pronto.#DefaultTerminal & {code: app}).out
	_cluster: (pronto.#DefaultCluster & {code: app, statics: []}).out
	_loop: (pronto.#DefaultLoop & {code: app, terminal: _terminal, cluster: _cluster}).out
	_build: (pronto.#DefaultBuild & {code: app, loop: _loop, cluster: _cluster, terminal: _terminal}).out
	out: (pronto.#emit & {
		code:     app
		cluster:  _cluster
		terminal: _terminal
		loop:     _loop
		build:    _build
	}).files
}

_machines: "services/database/migrations/010_machines.sql"
_effects:  "services/airlock/effects.json"
_origin:   "https://api.acquirer.example"
