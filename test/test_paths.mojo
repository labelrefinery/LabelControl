from paths import short_path
from std.testing import assert_equal, TestSuite


def test_under_the_run_root_becomes_relative() raises:
    assert_equal(
        short_path("/somewhere/runs/seed42/scene.mcap", "/somewhere/runs"),
        "seed42/scene.mcap",
    )


def test_the_root_itself() raises:
    assert_equal(short_path("/somewhere/runs", "/somewhere/runs"), "")


def test_outside_the_root_keeps_two_segments() raises:
    assert_equal(short_path("/a/b/c/d/e.csv", "/somewhere/runs"), "…/d/e.csv")


def test_a_short_path_is_left_alone() raises:
    assert_equal(short_path("/tmp", "/somewhere/runs"), "/tmp")


def test_an_empty_root_does_not_swallow_everything() raises:
    # an unset LABELCONTROL_WORK must not turn every path into a bare relative
    assert_equal(short_path("/a/b/c.csv", ""), "…/b/c.csv")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
