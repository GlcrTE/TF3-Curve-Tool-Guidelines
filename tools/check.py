"""Type-checks the mod's Teal scripts against the game's API definitions, verifies that
_content.json lists every content file (the game loads only listed files) and runs the tests.

Needs the `lupa` package (pip install lupa). The Teal compiler (tl.lua) is
downloaded once into tools/.cache.

Usage: python tools/check.py [--game "<TF3 install dir>"]
"""

import argparse
import glob
import json
import os
import sys
import urllib.request

from lupa import LuaRuntime

DEFAULT_GAME = r"D:\Games\SteamLibrary\steamapps\common\Transport Fever 3"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MOD_CONTENT = os.path.join(ROOT, "mod", "glcrte_precision_guidelines_1", "content")
CACHE = os.path.join(ROOT, "tools", ".cache")
TL_URL = "https://raw.githubusercontent.com/teal-language/tl/master/tl.lua"

LUA_CHECK = """
function(tl_path, files)
  local tl = dofile(tl_path)
  local env, err = tl.new_env({ predefined_modules = { "all_def" } })
  if not env then return "environment: " .. tostring(err) end
  local out = {}
  for _, f in ipairs(files) do
    local result, ferr = tl.check_file(f, env)
    if not result then
      table.insert(out, f .. ": " .. tostring(ferr))
    else
      for _, kind in ipairs({ "syntax_errors", "type_errors" }) do
        for _, e in ipairs(result[kind] or {}) do
          table.insert(out, (e.filename or f) .. ":" .. e.y .. ":" .. e.x .. ": " .. e.msg)
        end
      end
    end
  end
  return table.concat(out, string.char(10))
end
"""

LUA_LOAD = """
function(tl_path, file)
  local tl = dofile(tl_path)
  local fd = assert(io.open(file, "rb"))
  local code = fd:read("*a")
  fd:close()
  local lua_code, err = tl.gen(code)
  if not lua_code then error(file .. ": " .. tostring(err)) end
  return assert(load(lua_code, "@" .. file))()
end
"""


def lua_path(path):
    return path.replace("\\", "/")


def teal_compiler():
    path = os.path.join(CACHE, "tl.lua")
    if not os.path.exists(path):
        os.makedirs(CACHE, exist_ok=True)
        print(f"downloading {TL_URL}")
        urllib.request.urlretrieve(TL_URL, path)
    return lua_path(path)


def check_content_list():
    listed = json.load(open(os.path.join(MOD_CONTENT, "..", "_content.json")))["files"]
    actual = sorted(
        os.path.relpath(f, MOD_CONTENT).replace(os.sep, "/")
        for f in glob.glob(os.path.join(MOD_CONTENT, "**", "*"), recursive=True)
        if os.path.isfile(f)
    )
    if sorted(listed) != actual:
        print(f"_content.json is out of date, expected files: {actual}")
        return False
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game", default=DEFAULT_GAME)
    args = parser.parse_args()

    if not check_content_list():
        return 1

    tl_path = teal_compiler()
    game = lua_path(args.game)
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        f'package.path = "{game}/api/tealdef/?.lua;{game}/base/tealdef/?.lua;'
        f'{game}/vscode-template/?.lua;" .. package.path'
    )

    files = [lua_path(f) for f in glob.glob(os.path.join(MOD_CONTENT, "**", "*.tl"), recursive=True)]
    errors = lua.eval(LUA_CHECK)(tl_path, lua.table_from(files))
    if errors:
        print(errors)
        print("type check FAILED")
        return 1
    print(f"type check ok ({len(files)} files)")

    load = lua.eval(LUA_LOAD)
    failed = 0
    for test in sorted(glob.glob(os.path.join(ROOT, "tests", "*_test.lua"))):
        run = lua.execute(f'return dofile("{lua_path(test)}")')
        results = run(lambda f: load(tl_path, lua_path(os.path.join(MOD_CONTENT, f))))
        for name, ok, message in (tuple(r.values()) for r in results.values()):
            print(f"{'ok  ' if ok else 'FAIL'} {os.path.basename(test)}: {name}{'' if ok else ' - ' + str(message)}")
            failed += 0 if ok else 1
    if failed:
        print(f"{failed} test(s) FAILED")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
