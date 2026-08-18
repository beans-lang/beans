#!/usr/bin/env python3
"""Generate valid Beans programs that stress checked reflection actions."""

import argparse
import random
from pathlib import Path


HEADER = r'''import std.io
import std.reflect

pub class FuzzBox {
    pub number: int
    pub label: string

    pub fn init(number: int, move label: string) {
        self.number = number
        self.label = move label
    }

    pub fn add(value: int) -> int { return self.number + value }
}

pub struct Pair {
    pub label: string
    pub number: int
}

pub enum Token {
    empty
    pair(label: string, number: int)
}

pub fn add(left: int, right: int) -> int { return left + right }

fn main() {
'''

FOOTER = "}\n"


def function_call(index: int, rng: random.Random) -> str:
    left = rng.randrange(-100, 101)
    right = rng.randrange(-100, 101)
    return f'''    let function_{index}: reflect.Function = reflect.find_function("main.add").expect("add")
    let result_{index}: reflect.Value = function_{index}.call([reflect.value({left}), reflect.value({right})]).expect("call")
    io.println((result_{index} as? int).expect("int"))
'''


def class_construct(index: int, rng: random.Random) -> str:
    number = rng.randrange(0, 1000)
    label = f"box-{rng.randrange(0, 1000)}"
    return f'''    let made_{index}: reflect.Value = type_of(FuzzBox).initializer().expect("FuzzBox init").call([reflect.value({number}), reflect.value("{label}")]).expect("construct")
    let box_{index}: FuzzBox = (made_{index} as? FuzzBox).expect("FuzzBox")
    io.println("{{box_{index}.number}}:{{box_{index}.label}}")
'''


def field_action(index: int, rng: random.Random) -> str:
    before = rng.randrange(0, 100)
    after = rng.randrange(100, 200)
    return f'''    let object_{index}: FuzzBox = new FuzzBox({before}, "field")
    let receiver_{index}: reflect.Value = reflect.value(move object_{index})
    let field_{index}: reflect.Field = type_of(FuzzBox).field("number").expect("number")
    field_{index}.set(receiver_{index}, reflect.value({after})).expect("set")
    io.println((field_{index}.get(receiver_{index}).expect("get") as? int).expect("int"))
'''


def method_action(index: int, rng: random.Random) -> str:
    base = rng.randrange(0, 100)
    add = rng.randrange(0, 100)
    return f'''    let method_box_{index}: FuzzBox = new FuzzBox({base}, "method")
    let method_receiver_{index}: reflect.Value = reflect.value(move method_box_{index})
    let method_result_{index}: reflect.Value = type_of(FuzzBox).method("add").expect("add method").call(method_receiver_{index}, [reflect.value({add})]).expect("method call")
    io.println((method_result_{index} as? int).expect("int"))
'''


def struct_construct(index: int, rng: random.Random) -> str:
    number = rng.randrange(0, 1000)
    return f'''    let pair_value_{index}: reflect.Value = type_of(Pair).initializer().expect("Pair init").call([reflect.value("pair-{index}"), reflect.value({number})]).expect("Pair construct")
    let pair_{index}: Pair = (pair_value_{index} as? Pair).expect("Pair")
    io.println("{{pair_{index}.label}}:{{pair_{index}.number}}")
'''


def variant_make(index: int, rng: random.Random) -> str:
    number = rng.randrange(0, 1000)
    return f'''    let token_value_{index}: reflect.Value = type_of(Token).variant("pair").expect("pair").make([reflect.value("token-{index}"), reflect.value({number})]).expect("variant")
    let token_{index}: Token = (token_value_{index} as? Token).expect("Token")
    match token_{index} {{
        pair(label, number) => io.println("{{label}}:{{number}}"),
        empty => io.println("bad variant"),
    }}
'''


def rejected_call(index: int, rng: random.Random) -> str:
    if rng.randrange(2) == 0:
        arguments = "[reflect.value(1)]"
    else:
        arguments = "[reflect.value(\"wrong\"), reflect.value(2)]"
    return f'''    let rejected_{index}: reflect.Function = reflect.find_function("main.add").expect("add")
    match rejected_{index}.call({arguments}) {{
        ok(_) => io.println("bad rejection"),
        err(problem) => io.println(problem.kind()),
    }}
'''


def owned_value(index: int, rng: random.Random) -> str:
    first = rng.randrange(0, 100)
    second = rng.randrange(0, 100)
    return f'''    let values_{index}: List<int> = [{first}, {second}]
    let boxed_values_{index}: reflect.Value = reflect.value(move values_{index})
    let restored_values_{index}: List<int> = (move boxed_values_{index} as? List<int>).expect("List")
    io.println("{{restored_values_{index}[0]}}:{{restored_values_{index}[1]}}")
'''


TEMPLATES = (
    function_call,
    class_construct,
    field_action,
    method_action,
    struct_construct,
    variant_make,
    rejected_call,
    owned_value,
)


def generate(seed: int, cases: int) -> str:
    rng = random.Random(seed)
    body = [rng.choice(TEMPLATES)(index, rng) for index in range(cases)]
    return HEADER + "\n".join(body) + FOOTER


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--cases", type=int, default=20)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.cases < 1:
        parser.error("--cases must be positive")
    args.output.write_text(generate(args.seed, args.cases))


if __name__ == "__main__":
    main()
