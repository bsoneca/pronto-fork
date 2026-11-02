# local-gate-key.nu: the ledger of the release's local pre-gate. A tree that passed
# `integrate@local` with INTEGRATE_LOCAL_DRIVERS=all on this machine is stamped under
# ~/.cache/pronto/local-gate/<app>/<key>, and release@gcp skips the gate for a tree
# with a stamp (docs/release-targets.md#gcp). The key is a hash of the app's files as git
# sees them (tracked and untracked, not ignored: a changed or new file changes it)
# and of the pronto files the gate runs, so another pronto version never matches.
# The one place the key is computed: release.nu uses it, integrate-local.ts runs `stamp`.
#
#   nu gcp/local-gate-key.nu key|passed|stamp <app dir>

const pronto = (path self ..)
const gate_files = ["integrate-local.ts" "local-drivers.ts" "plugin.json"]

def stamp-dir [app_dir: string]: nothing -> string {
	$env.HOME | path join .cache pronto local-gate ($app_dir | path expand | path basename)
}

# The key of the tree as it stands, or null where git cannot read it (no ledger then).
export def key [app_dir: string]: nothing -> any {
	let dir = ($app_dir | path expand)
	let listed = (do { ^git -C $dir ls-files -co --exclude-standard } | complete)
	if $listed.exit_code != 0 { return null }
	let files = ($listed.stdout | lines | where {|f| ($dir | path join $f | path type) in [file symlink] })
	let hashed = ($files | str join (char nl) | do { ^git -C $dir hash-object --stdin-paths } | complete)
	if $hashed.exit_code != 0 { return null }
	let own = ($gate_files | each {|f| open --raw ($pronto | path join $f) | hash sha256 })
	[...$files ...($hashed.stdout | lines) ...$own] | str join (char nl) | hash sha256
}

# Whether this tree passed the local gate on this machine.
export def passed [app_dir: string]: nothing -> bool {
	let k = (key $app_dir)
	$k != null and ((stamp-dir $app_dir | path join $k) | path exists)
}

# The stamp of a pass, for the tree whose key is given (the key taken before the gate ran).
export def stamp [app_dir: string, k?: string] {
	let k = ($k | default (key $app_dir))
	if $k == null { return }
	mkdir (stamp-dir $app_dir)
	(date now | format date "%+") | save -f (stamp-dir $app_dir | path join $k)
}

def main [verb: string, app_dir: string] {
	match $verb {
		"key" => { print (key $app_dir) }
		"passed" => { print (passed $app_dir) }
		"stamp" => { stamp $app_dir }
		_ => { error make {msg: $"local-gate-key.nu: unknown verb ($verb): key, passed or stamp"} }
	}
}
