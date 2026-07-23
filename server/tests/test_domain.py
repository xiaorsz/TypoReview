import unittest
from datetime import datetime, timezone

from app.domain import apply_review_result, is_due


def item(stage: int = 0, next_review_at: str = "2026-07-23T00:00:00.000Z") -> dict:
    return {
        "id": "00000000-0000-0000-0000-000000000010",
        "stage": stage,
        "nextReviewAt": next_review_at,
        "consecutiveCorrectCount": 0,
        "consecutiveWrongCount": 0,
        "reviewTrackRawValue": "standard",
        "dictationFollowUpStep": 0,
        "isDictationPassRaw": False,
    }


class DomainTests(unittest.TestCase):
    def test_first_correct_jumps_to_stage_two(self):
        reviewed_at = datetime(2026, 7, 23, 2, tzinfo=timezone.utc)
        updated, old_stage, new_stage = apply_review_result(item(), result="correct", reviewed_at=reviewed_at)
        self.assertEqual((old_stage, new_stage), (0, 2))
        self.assertEqual(updated["nextReviewAt"], "2026-07-24T16:00:00.000Z")

    def test_correct_at_final_stage_marks_distant_future(self):
        reviewed_at = datetime(2026, 7, 23, 2, tzinfo=timezone.utc)
        updated, _, new_stage = apply_review_result(item(stage=6), result="correct", reviewed_at=reviewed_at)
        self.assertEqual(new_stage, 7)
        self.assertTrue(updated["nextReviewAt"].startswith("4001-01-01"))

    def test_wrong_moves_back_one_stage(self):
        reviewed_at = datetime(2026, 7, 23, 2, tzinfo=timezone.utc)
        updated, _, new_stage = apply_review_result(item(stage=4), result="wrong", reviewed_at=reviewed_at)
        self.assertEqual(new_stage, 3)
        self.assertEqual(updated["nextReviewAt"], "2026-07-26T16:00:00.000Z")

    def test_due_uses_shanghai_natural_day(self):
        self.assertTrue(is_due(item(next_review_at="2026-07-22T16:00:00.000Z"), datetime(2026, 7, 23).date()))


if __name__ == "__main__":
    unittest.main()
