# orchestrator/

The run driver: restore snapshot → start server → readiness gate → discard warm-up →
measure → collect client+server metrics → cooldown → teardown, ×N reps, writing a run
manifest. Added in plan step 6.
