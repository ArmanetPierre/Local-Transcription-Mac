"""Tests des fonctions pures de transcribe_bridge.py (sans charger de modele)."""

import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RESOURCES = os.path.join(HERE, "..", "..", "TranscriptionApp", "TranscriptionApp", "Resources")
sys.path.insert(0, os.path.abspath(RESOURCES))

import transcribe_bridge as bridge  # noqa: E402  (imports lourds : torch, mlx, pyannote)
from pyannote.core import Annotation, Segment  # noqa: E402


def annotation(*turns):
    ann = Annotation()
    for start, end, speaker in turns:
        ann[Segment(start, end)] = speaker
    return ann


class CosineSimilarityTests(unittest.TestCase):
    def test_identical_vectors(self):
        self.assertAlmostEqual(bridge.cosine_similarity([1, 2, 3], [1, 2, 3]), 1.0, places=5)

    def test_orthogonal_vectors(self):
        self.assertAlmostEqual(bridge.cosine_similarity([1, 0], [0, 1]), 0.0, places=5)

    def test_zero_vector(self):
        self.assertEqual(bridge.cosine_similarity([0, 0], [1, 1]), 0.0)


class MatchSpeakersTests(unittest.TestCase):
    def test_matches_best_score_without_duplicates(self):
        new = {"SPEAKER_00": [1.0, 0.0, 0.0], "SPEAKER_01": [0.9, 0.1, 0.0]}
        saved = {"Olivier": [1.0, 0.0, 0.0], "Pierre": [0.0, 1.0, 0.0]}
        matches = bridge.match_speakers_with_saved(new, saved, threshold=0.65)
        # SPEAKER_00 prend Olivier (score 1.0) ; SPEAKER_01 ne peut pas reprendre Olivier
        self.assertEqual(matches, {"SPEAKER_00": "Olivier"})

    def test_below_threshold_is_not_matched(self):
        matches = bridge.match_speakers_with_saved({"SPEAKER_00": [1.0, 0.0]}, {"Pierre": [0.5, 0.86]}, threshold=0.65)
        self.assertEqual(matches, {})

    def test_mismatched_dimensions_are_ignored(self):
        new = {"SPEAKER_00": [1.0] * 256}
        saved = {"Test": [1.0] * 192, "Olivier": [1.0] * 256}
        self.assertEqual(bridge.match_speakers_with_saved(new, saved), {"SPEAKER_00": "Olivier"})

    def test_empty_inputs(self):
        self.assertEqual(bridge.match_speakers_with_saved({}, {"A": [1.0]}), {})
        self.assertEqual(bridge.match_speakers_with_saved({"S": [1.0]}, {}), {})


class LoadEmbeddingsTests(unittest.TestCase):
    def test_missing_file_returns_empty(self):
        self.assertEqual(bridge.load_embeddings_file("/nonexistent/embeddings.json"), {})
        self.assertEqual(bridge.load_embeddings_file(None), {})

    def test_reads_json(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"Pierre": [0.1, 0.2]}, f)
        try:
            self.assertEqual(bridge.load_embeddings_file(f.name), {"Pierre": [0.1, 0.2]})
        finally:
            os.remove(f.name)

    def test_invalid_json_returns_empty(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write("{not json")
        try:
            self.assertEqual(bridge.load_embeddings_file(f.name), {})
        finally:
            os.remove(f.name)


class AssignSpeakersTests(unittest.TestCase):
    def test_segment_gets_speaker_with_most_overlap(self):
        segments = [{"start": 0.0, "end": 10.0, "text": "a"}]
        diarization = annotation((0, 3, "SPEAKER_00"), (3, 10, "SPEAKER_01"))
        bridge.assign_speakers_to_segments(segments, diarization)
        self.assertEqual(segments[0]["speaker"], "SPEAKER_01")

    def test_segment_without_overlap_is_unknown(self):
        segments = [{"start": 20.0, "end": 25.0, "text": "a"}]
        bridge.assign_speakers_to_segments(segments, annotation((0, 10, "SPEAKER_00")))
        self.assertEqual(segments[0]["speaker"], "Inconnu")

    def test_each_segment_assigned_independently(self):
        segments = [{"start": 0.0, "end": 4.0, "text": "a"}, {"start": 5.0, "end": 9.0, "text": "b"}]
        diarization = annotation((0, 4.5, "SPEAKER_00"), (4.5, 9, "SPEAKER_01"))
        bridge.assign_speakers_to_segments(segments, diarization)
        self.assertEqual([s["speaker"] for s in segments], ["SPEAKER_00", "SPEAKER_01"])


if __name__ == "__main__":
    unittest.main()
