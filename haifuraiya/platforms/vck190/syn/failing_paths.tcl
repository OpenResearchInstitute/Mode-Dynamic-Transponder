open_project mdt_vck190_playback_project/mdt_vck190_playback.xpr
open_run impl_1
report_timing -slack_lesser_than 0 -max_paths 200 -nworst 1 -file failing_paths.rpt
