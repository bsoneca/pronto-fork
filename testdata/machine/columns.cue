package machine

import "strings"

// Columns: the field a machine holds, its default, its check and what the
// shell is told of it.

admits: "the machine supplies the column default and check so an omitted status starts legally": {
	program: _challenge
	expect: sql: {
		value: program.out["services/database/migrations/005_create_tables.sql"].text
		has: [#""status" text DEFAULT 'pending' NOT NULL CHECK ("status" IN ("#, "'pending'", "'accepted'", "'declined'", "'expired'"]
	}
}

refuses: "a machine refuses a conflicting default": {
	program: _challenge & {with: status: default: "'accepted'"}
	says: ["disagrees with Challenge.status default"]
}

refuses: "a machine refuses a closed enum missing a state": {
	program: _challenge & {app: state: entities: Challenge: cel: enums: status: ["pending"]}
	says: ["is not admitted by Challenge.status cel enum"]
}

refuses: "a machine refuses a seed outside its states": {
	program: _challenge & {app: state: entities: Challenge: seed: [{status: "lost"}]}
	says: ["value lost is not a state"]
}

admits: "a matching default and CEL check remain the column's one declared constraint": {
	program: _challenge & {
		with: status: {default: "'pending'", cel: "this in ['pending', 'accepted', 'declined', 'expired']"}
		app: state: entities: Challenge: {
			cel: {checks: status: "status IN ('pending', 'accepted', 'declined', 'expired')", enums: status: ["pending", "accepted", "declined", "expired"]}
			seed: [{status: "pending"}]
		}
	}
	let line = [for l in strings.Split(program.out["services/database/migrations/005_create_tables.sql"].text, "\n") if strings.Contains(l, #""status""#) {l}][0]
	expect: constraints: {value: {defaults: strings.Count(line, "DEFAULT"), checks: strings.Count(line, "CHECK")}, equals: {defaults: 1, checks: 1}}
}

for k, attribute in {generated: {generated: "'pending'"}, retired: {retired: true}} {
	refuses: "machine transitions cannot occupy \(k) columns": {
		program: _challenge & {with: status: attribute}
		says: ["machine ChallengeMachine field Challenge.status", "is \(k) and cannot hold transitions"]
	}
}

admits: "shell schema sends typed literal defaults and leaves SQL expressions with the store": {
	program: _challenge & {with: tail: [
		{name: "created_at", type: "timestamp", default: "now()"},
		{name: "label", type: "string", default: "'can''t'"},
		{name: "empty", type: "string", default: "''"},
		{name: "count", type: "int32", default: "-12"},
		{name: "ratio", type: "double", default: "+1.5e2"},
		{name: "large", type: "int64", default: "9007199254740993"},
		{name: "legacy_large", type: "bigint", default: "+9007199254740993"},
		{name: "precise", type: "decimal", precision: 38, scale: 18, default: "12345678901234567890.123456789012345678"},
		{name: "exponent", type: "decimal", precision: 38, scale: 20, default: "1.2300e-18"},
		{name: "integer_exponent", type: "int64", default: "1.20e2"},
		{name: "rounded_integer", type: "int64", default: "1.5"},
		{name: "quoted_false", type: "bool", default: "'false'"},
		{name: "quoted_json", type: "json", default: #"'{"n":1}'"#},
		{name: "quoted_bytes", type: "bytes", default: "'abcd'"},
		{name: "zero", type: "decimal", precision: 3, scale: 2, default: "-0.00"},
		{name: "yes", type: "bool", default: "TRUE"},
		{name: "no", type: "bool", default: "false"},
		{name: "absent", type: "string", required: false, default: "NULL"},
		{name: "expression", type: "uuid", default: "gen_random_uuid()"},
		{name: "quoted_expr", type: "string", default: "'a' || 'b'"},
	]}
	let fields = program.out["shell/shell.yaml"].data.schema.challenge.fields
	expect: {
		defaults: {
			value: {for f in fields if f.default != _|_ {(f.name): f.default}}
			equals: {
				status:   "pending", label:                           "can't", empty:              "", count: -12, ratio: 150, yes: true, no: false, absent: null
				large:    "9007199254740993", legacy_large:           "9007199254740993", precise: "12345678901234567890.123456789012345678"
				exponent: "0.00000000000000000123", integer_exponent: "120", zero:                 "0"
			}
		}
		undefaulted: {value: [for f in fields if f.name != "id" if (f.defaulted & true) == _|_ {f.name}], equals: []}
		idDefaulted: {value: [for f in fields if f.name == "id" if f.defaulted != _|_ {f.name}], equals: []}
	}
}

// The runner also hands `schema` to omnishell's markup gate.
admits: "omitting SQL expression values preserves the markup gate for pending discriminants": {
	program: _challenge & {
		with: tail: [{name: "kind", type: "string", default: "choose_kind()", cel: "this in ['note', 'link']"}]
		app: state: entities: Challenge: cel: enums: kind: ["note", "link"]
	}
	let s = program.out["shell/shell.yaml"].data.schema
	let k = [for f in s.challenge.fields if f.name == "kind" {f}][0]
	expect: {
		kind: {value: {defaulted: k.defaulted, hasDefault: k.default != _|_, enum: k.enum}, equals: {defaulted: true, hasDefault: false, enum: ["note", "link"]}}
		schema: value: s
	}
}
