"""Tests des fonctions pures de transcribe_bridge.py (sans charger de modele)."""

import json
import os
import sys
import tempfile
import unittest
from unittest import mock

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


class GalleryTests(unittest.TestCase):
    def test_parse_v1_wraps_single_embedding(self):
        self.assertEqual(bridge.parse_gallery({"Pierre": [0.1, 0.2]}), {"Pierre": [[0.1, 0.2]]})

    def test_parse_v2(self):
        data = {"version": 2, "speakers": {"Pierre": [{"embedding": [1.0, 0.0], "source": "x"},
                                                      {"embedding": [0.0, 1.0]}]}}
        self.assertEqual(bridge.parse_gallery(data), {"Pierre": [[1.0, 0.0], [0.0, 1.0]]})

    def test_best_sample_wins(self):
        # La voix "visio" de Pierre ne ressemble qu'a sa deuxieme empreinte
        gallery = {"version": 2, "speakers": {
            "Pierre": [{"embedding": [1.0, 0.0, 0.0]}, {"embedding": [0.0, 1.0, 0.0]}],
            "Olivier": [{"embedding": [0.0, 0.0, 1.0]}]}}
        scores = {}
        matches = bridge.match_speakers_with_saved({"SPEAKER_00": [0.05, 1.0, 0.0]}, gallery, scores_out=scores)
        self.assertEqual(matches, {"SPEAKER_00": "Pierre"})
        self.assertGreater(scores["SPEAKER_00"], 0.99)

    def test_speaker_scores_ignore_other_dimensions(self):
        scores = bridge.speaker_scores({"S": [1.0, 0.0]}, {"A": [[1.0, 0.0], [1.0, 0.0, 0.0]]})
        self.assertAlmostEqual(scores["S"]["A"], 1.0, places=5)


class LoadEmbeddingsTests(unittest.TestCase):
    def test_missing_file_returns_empty(self):
        self.assertEqual(bridge.load_embeddings_file("/nonexistent/embeddings.json"), {})
        self.assertEqual(bridge.load_embeddings_file(None), {})

    def test_reads_json(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"Pierre": [0.1, 0.2]}, f)
        try:
            self.assertEqual(bridge.load_embeddings_file(f.name), {"Pierre": [[0.1, 0.2]]})
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


def word(text, start, end):
    return {"word": text, "start": start, "end": end, "probability": 0.9}


class SplitBySpeakerTests(unittest.TestCase):
    def test_segment_is_split_at_speaker_change(self):
        segments = [{"start": 0.0, "end": 4.0, "text": " je t'explique en fait c'est simple", "words": [
            word(" je", 0.0, 0.3), word(" t'explique", 0.3, 0.9), word(" en", 0.9, 1.1),
            word(" fait", 2.1, 2.4), word(" c'est", 2.4, 2.8), word(" simple", 2.8, 3.5)]}]
        diarization = annotation((0, 1.5, "SPEAKER_01"), (1.8, 4, "SPEAKER_00"))
        out = bridge.split_segments_by_speaker(segments, diarization)
        self.assertEqual([(s["speaker"], s["text"]) for s in out],
                         [("SPEAKER_01", "je t'explique en"), ("SPEAKER_00", "fait c'est simple")])
        self.assertEqual((out[1]["start"], out[1]["end"]), (2.1, 3.5))
        self.assertNotIn("words", out[0])

    def test_word_in_short_gap_goes_to_nearest_turn(self):
        segments = [{"start": 0.0, "end": 6.0, "text": "", "words": [
            word(" oui", 0.0, 0.4), word(" tout", 0.5, 0.8), word(" à", 0.9, 1.0), word(" fait", 1.6, 2.0),
            word(" mais", 3.0, 3.3), word(" pas", 3.4, 3.7), word(" ici.", 3.8, 4.6)]}]
        diarization = annotation((0, 1.2, "A"), (2.6, 6.0, "B"))
        out = bridge.split_segments_by_speaker(segments, diarization)
        # "fait" (1.6-2.0) tombe dans le silence, plus pres de A
        self.assertEqual([(s["speaker"], s["text"]) for s in out],
                         [("A", "oui tout à fait"), ("B", "mais pas ici.")])

    def test_isolated_word_stays_in_its_sentence(self):
        # "La reserve legale, c'est 5% du benefice | dans | la limite de 10% du capital."
        words = [word(w, i * 0.4, i * 0.4 + 0.35) for i, w in enumerate(
            " La réserve légale, c'est 5% du bénéfice dans la limite de 10% du capital.".split(" ")[1:])]
        for w in words:
            w["word"] = " " + w["word"]
        diarization = annotation((0, 2.75, "S2"), (2.8, 3.15, "S1"), (3.2, 10, "S2"))
        out = bridge.split_segments_by_speaker([{"start": 0, "end": 6, "text": "", "words": words}], diarization)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["speaker"], "S2")

    def test_first_word_of_new_sentence_follows_the_sentence(self):
        # "...on fait le capital. Et | on l'a aussi dans les documents" : "Et" ouvre la phrase de S2
        texts = [" Le", " capital", " social.", " Et", " on", " l'a", " aussi", " dans", " les", " documents."]
        words = [word(w, i * 0.5, i * 0.5 + 0.45) for i, w in enumerate(texts)]
        diarization = annotation((0, 1.9, "S1"), (1.95, 2.0, "S1"), (2.0, 2.4, "S1"), (2.45, 6, "S2"))
        # "Et" (1.5-1.95) est encore dans le tour de S1
        out = bridge.split_segments_by_speaker([{"start": 0, "end": 5, "text": "", "words": words}], diarization)
        self.assertEqual([(s["speaker"], s["text"]) for s in out],
                         [("S1", "Le capital social."), ("S2", "Et on l'a aussi dans les documents.")])

    def test_segment_without_words_is_assigned_whole(self):
        segments = [{"start": 0.0, "end": 4.0, "text": "bonjour"}]
        out = bridge.split_segments_by_speaker(segments, annotation((0, 4, "A")))
        self.assertEqual(out[0]["speaker"], "A")

    def test_far_from_any_turn_is_unknown(self):
        segments = [{"start": 50.0, "end": 51.0, "text": "x", "words": [word(" x", 50.0, 51.0)]}]
        out = bridge.split_segments_by_speaker(segments, annotation((0, 4, "A")))
        self.assertEqual(out[0]["speaker"], "Inconnu")


def words_of(text, start=0.0):
    return [word(" " + w, start + i * 0.3, start + i * 0.3 + 0.25) for i, w in enumerate(text.split())]


class HallucinationLoopTests(unittest.TestCase):
    def test_single_word_loop_collapsed(self):
        kept = bridge.collapse_repetitions(words_of("pour le fnb " + "la " * 60 + "et voilà"))
        self.assertEqual(" ".join(w["word"].strip() for w in kept), "pour le fnb la et voilà")

    def test_phrase_loop_collapsed(self):
        kept = bridge.collapse_repetitions(words_of("ok on y va " * 6 + "fin"))
        self.assertEqual(" ".join(w["word"].strip() for w in kept), "ok on y va fin")

    def test_natural_repetition_kept(self):
        text = "non non non je ne pense pas"
        kept = bridge.collapse_repetitions(words_of(text))
        self.assertEqual(" ".join(w["word"].strip() for w in kept), text)

    def test_punctuation_and_case_ignored(self):
        kept = bridge.collapse_repetitions(words_of("Voilà, voilà. voilà voilà voilà ok"))
        self.assertEqual(len(kept), 2)

    def test_segment_text_rebuilt(self):
        segs = [{"start": 0, "end": 30, "text": "x", "words": words_of("bon " + "la " * 10)}]
        out = bridge.remove_hallucination_loops(segs)
        self.assertEqual(out[0]["text"].strip(), "bon la")
        self.assertAlmostEqual(out[0]["end"], 0.55)


class DiarizationPipelineTests(unittest.TestCase):
    def test_prefers_community_1(self):
        with mock.patch.object(bridge.PyannotePipeline, "from_pretrained", return_value="P") as load:
            pipeline, name = bridge.load_diarization_pipeline("tok")
        self.assertEqual((pipeline, name), ("P", "pyannote/speaker-diarization-community-1"))
        load.assert_called_once_with("pyannote/speaker-diarization-community-1", token="tok")

    def test_falls_back_to_3_1_when_community_1_unavailable(self):
        def fake(name, token=None):
            if "community" in name:
                raise RuntimeError("gated repo: accept the conditions")
            return "P31"
        with mock.patch.object(bridge.PyannotePipeline, "from_pretrained", side_effect=fake):
            self.assertEqual(bridge.load_diarization_pipeline("tok"),
                             ("P31", "pyannote/speaker-diarization-3.1"))

    def test_raises_when_nothing_available(self):
        with mock.patch.object(bridge.PyannotePipeline, "from_pretrained", side_effect=RuntimeError("offline")):
            with self.assertRaises(RuntimeError):
                bridge.load_diarization_pipeline(None)

    def test_forced_model_has_no_fallback(self):
        with mock.patch.object(bridge.PyannotePipeline, "from_pretrained", side_effect=RuntimeError("no")) as load:
            with self.assertRaises(RuntimeError):
                bridge.load_diarization_pipeline("tok", "pyannote/speaker-diarization-3.1")
        self.assertEqual(load.call_count, 1)


if __name__ == "__main__":
    unittest.main()
