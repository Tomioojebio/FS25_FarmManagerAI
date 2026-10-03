#!/usr/bin/env python3
"""Run Lua logic/contract tests using the installed Lua 5.4 shared library.
This is not the proprietary GIANTS runtime and is not an in-game test.
"""
import ctypes
import ctypes.util
import pathlib
import os
import sys

lib = ctypes.CDLL(ctypes.util.find_library("lua5.4"))
lib.luaL_newstate.restype = ctypes.c_void_p
lib.luaL_openlibs.argtypes = [ctypes.c_void_p]
lib.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
lib.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ctypes.c_void_p]
lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
lib.lua_tolstring.restype = ctypes.c_char_p
lib.lua_close.argtypes = [ctypes.c_void_p]

root = pathlib.Path(__file__).resolve().parents[1]
os.chdir(root)
failed = 0
for path in sorted((root / "scripts").glob("*.lua")):
    state = lib.luaL_newstate()
    if lib.luaL_loadfilex(state, str(path).encode(), None):
        print("SYNTAX FAIL", path.name, lib.lua_tolstring(state, -1, None).decode())
        failed += 1
    lib.lua_close(state)
print("Syntax checked:", len(list((root / "scripts").glob("*.lua"))), flush=True)
if not failed:
    state = lib.luaL_newstate()
    lib.luaL_openlibs(state)
    status = lib.luaL_loadfilex(state, str(root / "developer/test_farm.lua").encode(), None)
    if not status:
        status = lib.lua_pcallk(state, 0, 0, 0, 0, None)
    if status:
        print("TEST FAILURE:", lib.lua_tolstring(state, -1, None).decode())
        failed += 1
    lib.lua_close(state)
sys.exit(1 if failed else 0)
