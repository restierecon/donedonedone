# Notes

## Purpose
An in-memory notes library: the eval runner's throwaway project.

## Stack
Python 3 standard library only; tests with unittest.

## Gate
- gate.test: python3 -m unittest discover -s tests -q
- gate.test.focus: python3 -m unittest -q {}
- gate.test.budget: 60

## Domain Language
| Term | Meaning |
|---|---|
| note | A title and a body kept by NoteStore |

## Autonomy
Autonomy: semi

## Parallelism
max_parallel_slices: 3

## Definition of Done
Every slice independently testable, no TODO/FIXME, no comments, gates green.
