discard """
  action: "reject"
  exitcode: 1
"""
import ../src/classes

class A*:
  discard

class B of distinct A:
  discard

class C(B):
  discard