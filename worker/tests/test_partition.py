import random
import unittest

from afterword_worker.protocol import WorkerError
from afterword_worker.summary import partition


class PartitionTests(unittest.TestCase):
    def test_repeated_similar_groups_do_not_restart_expensive_search(self):
        evaluated = set()
        def fits(group):
            evaluated.add(tuple(group))
            return len(group) <= 50
        groups = partition(list(range(1000)), lambda group: group, fits)
        self.assertEqual([len(group) for group in groups], [50] * 20)
        self.assertEqual([item for group in groups for item in group], list(range(1000)))
        self.assertLess(len(evaluated), 100)

    def test_random_positive_weights_match_linear_maximum_prefix_oracle(self):
        generator = random.Random(8721)
        for _ in range(250):
            budget = generator.randint(1, 100)
            items = [(index, generator.randint(1, budget)) for index in range(generator.randint(0, 120))]
            expected, remaining = [], list(items)
            while remaining:
                total, count = 0, 0
                for _, weight in remaining:
                    if total + weight > budget: break
                    total += weight
                    count += 1
                expected.append(remaining[:count])
                remaining = remaining[count:]
            actual = partition(items, lambda group: group, lambda group: sum(item[1] for item in group) <= budget)
            self.assertEqual(actual, expected)

    def test_oversized_items_are_split_in_place_without_losing_order(self):
        groups = partition(["abc", "ABCDEFGHIJK", "def"], lambda group: group,
                           lambda group: sum(map(len, group)) <= 5,
                           lambda item: [item[:len(item) // 2], item[len(item) // 2:]])
        self.assertEqual("".join(item for group in groups for item in group), "abcABCDEFGHIJKdef")
        self.assertTrue(all(sum(map(len, group)) <= 5 for group in groups))
        with self.assertRaises(WorkerError):
            partition(["too large"], lambda group: group, lambda _: False, lambda item: [item])
