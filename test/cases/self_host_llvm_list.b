import std.io

fn sum(values: List<int>) -> int {
    var result: int = 0
    for value: int in values {
        result += value
    }
    return result
}

fn main() {
    let values: List<int> = [1, 2, 3]
    io.println(values.len())
    io.println(values[1])
    io.println(sum(values))

    let narrow: List<i8> = [-2, 127]
    io.println(narrow[0])
    io.println(narrow[1])

    let fractions: List<f32> = [1.5, -2.25]
    io.println(fractions[0])
    io.println(fractions[1])

    var words: List<string> = ["one", "two"]
    words.reserve(8)
    words.push("three")
    words.insert(1, "middle")
    io.println(words[0])
    for word: string in words {
        io.println(word)
    }
    io.println(words.remove(0))
    io.println(words.first().or("empty"))
    io.println(words.last().or("empty"))
    io.println(words.pop().or("empty"))
    let word_slice: List<string> = words.slice(0, 2)
    io.println(word_slice.len())
    var empty_words: List<string> = []
    io.println(empty_words.pop().or("empty"))

    let nested: List<List<int>> = [[4, 5], [6]]
    var nested_sum: int = 0
    for part: List<int> in nested {
        for value: int in part {
            nested_sum += value
        }
    }
    io.println(nested_sum)

    var sorted: List<int> = [3, 1, 2]
    sorted.sort()
    io.println(sorted[0])
    io.println(sorted[2])
}
