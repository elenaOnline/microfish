//! Runs a Lua file in the same kind of `LuaJIT` state the engine builds (`StdLib::ALL`), with
//! `arg` set. A CLI with no UI and no permissions: used to check what `LuaJIT` needs under the
//! hardened runtime (see `app/Packaging/Engine.entitlements`) and that the product's Lua loads.
//!
//! ```text
//! cargo run --example lua_probe -- app/Tests/jit-probe.lua
//! ```
use mlua::{Lua, LuaOptions, StdLib};

fn main() -> mlua::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let path = args.first().expect("usage: lua_probe <script.lua> [args...]");
    // SAFETY: as in the engine; the state stays on this thread and `ffi` is wanted.
    let lua = unsafe { Lua::unsafe_new_with(StdLib::ALL, LuaOptions::new()) };
    let arg = lua.create_table()?;
    for (index, value) in args.iter().enumerate() {
        arg.set(index, value.as_str())?;
    }
    lua.globals().set("arg", arg)?;
    let source = std::fs::read_to_string(path).map_err(mlua::Error::external)?;
    lua.load(source).set_name(format!("@{path}")).exec()
}
