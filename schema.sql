-- oracle-gate: clean-room schema
-- Extracted from production GABS multi-agent system (CozyAF LLC)
-- License: MIT
--
-- Three tables + two trigger functions + one circuit breaker.
-- Drop this into any Supabase/Postgres project. Requires pgcrypto (gen_random_uuid).

-- ============================================================
-- 1. oracle_queue
--    Builder agents INSERT here when they think work is done.
--    Status lifecycle: pending -> running -> done | failed_to_dispatch
-- ============================================================
CREATE TABLE IF NOT EXISTS oracle_queue (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_slug           TEXT NOT NULL,
  deploy_url             TEXT NOT NULL,
  spec_ref               TEXT,
  builder_agent          TEXT NOT NULL,
  changed_functions      JSONB DEFAULT '[]'::jsonb,
  build_hash             TEXT,
  attempt_number         INTEGER DEFAULT 1,
  status                 TEXT DEFAULT 'pending',
  dispatched_to_session_id UUID,
  created_at             TIMESTAMPTZ DEFAULT now(),
  dispatched_at          TIMESTAMPTZ,
  completed_at           TIMESTAMPTZ,
  -- Fortune Teller integration (optional, remove if not using FT)
  ft_t2_verdict_id       UUID,
  ft_bypass_decision_id  UUID,
  ft_bypass_reason       TEXT
);

-- ============================================================
-- 2. oracle_verdicts
--    The Oracle reviewer writes its verdict here.
--    verdict IN ('pass', 'fail', 'blocked')
-- ============================================================
CREATE TABLE IF NOT EXISTS oracle_verdicts (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  queue_id          UUID REFERENCES oracle_queue(id),
  project_slug      TEXT NOT NULL,
  verdict           TEXT NOT NULL CHECK (verdict IN ('pass', 'fail', 'blocked')),
  bugs_found        JSONB DEFAULT '[]'::jsonb,
  fix_instructions  TEXT,
  functions_tested  JSONB DEFAULT '[]'::jsonb,
  spec_deviations   JSONB DEFAULT '[]'::jsonb,
  observations      JSONB DEFAULT '[]'::jsonb,
  screenshots       JSONB DEFAULT '[]'::jsonb,
  console_log       TEXT,
  magicians_tell    TEXT,
  model_used        TEXT DEFAULT 'claude-opus-4-7',
  duration_seconds  NUMERIC,
  total_cost_usd    NUMERIC,
  signed_at         TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 3. oracle_circuit_breaker
--    Tracks consecutive failures per project.
--    At 3 consecutive fails, escalates to a human.
-- ============================================================
CREATE TABLE IF NOT EXISTS oracle_circuit_breaker (
  project_slug       TEXT PRIMARY KEY,
  consecutive_failures INTEGER DEFAULT 0,
  last_failure_at    TIMESTAMPTZ,
  last_escalated_at  TIMESTAMPTZ,
  escalation_count   INTEGER DEFAULT 0,
  updated_at         TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- 4. claim_gate function (dispatch on queue insert)
--    When a row lands in oracle_queue, this trigger:
--      a) checks the self-audit firewall (builder cannot review own work)
--      b) dispatches an oracle_handoff directive to the reviewer agent
-- ============================================================
CREATE OR REPLACE FUNCTION oracle_dispatch_on_queue_insert()
RETURNS TRIGGER AS $$
DECLARE
  v_firewall_blocked BOOLEAN := false;
  v_recent_builder_count INTEGER := 0;
BEGIN
  -- Self-audit firewall: if the builder agent recently built this project,
  -- they cannot also be the Oracle reviewer. Block and escalate.
  IF NEW.builder_agent IN ('cowork', 'honey_badger') THEN
    SELECT count(*) INTO v_recent_builder_count
    FROM agent_sessions
    WHERE source != 'oracle'
      AND project_slug = NEW.project_slug
      AND started_at > now() - interval '2 hours';

    IF v_recent_builder_count > 0 THEN
      v_firewall_blocked := true;
    END IF;
  END IF;

  IF v_firewall_blocked THEN
    -- Firewall tripped. Escalate: Oracle cannot self-audit.
    INSERT INTO agent_scratchpad (from_agent, to_agent, message_type, priority, subject, content)
    VALUES (
      'oracle', 'brain', 'flag', 'high',
      'Oracle self-audit firewall tripped',
      'Build ' || NEW.id::text || ' for ' || NEW.project_slug ||
      ' was built by the same agent within 2 hours. Needs human or alternate reviewer.'
    );
    UPDATE oracle_queue SET status = 'failed_to_dispatch' WHERE id = NEW.id;
  ELSE
    -- Dispatch: write oracle_handoff directive to the reviewer agent.
    INSERT INTO agent_scratchpad (from_agent, to_agent, message_type, priority, subject, content)
    VALUES (
      'oracle', 'reviewer', 'oracle_handoff', 'high',
      'Oracle review requested: ' || NEW.project_slug,
      'queue_id=' || NEW.id::text ||
      E'\nproject_slug=' || NEW.project_slug ||
      E'\ndeploy_url=' || NEW.deploy_url ||
      E'\nspec_ref=' || COALESCE(NEW.spec_ref, 'see latest memory') ||
      E'\nbuilder_agent=' || NEW.builder_agent ||
      E'\nattempt_number=' || NEW.attempt_number::text ||
      E'\n---\nEnter oracle_mode. Load oracle system prompt. Run adversarial review. Write verdict to oracle_verdicts.'
    );
    UPDATE oracle_queue SET status = 'running', dispatched_at = now() WHERE id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_oracle_dispatch
  AFTER INSERT ON oracle_queue
  FOR EACH ROW
  EXECUTE FUNCTION oracle_dispatch_on_queue_insert();

-- ============================================================
-- 5. Verdict router (route on verdict insert)
--    When the Oracle writes a verdict:
--      pass  -> reset circuit breaker, notify brain
--      fail  -> increment circuit breaker, route fix instructions back to builder
--               (at 3 consecutive fails, escalate to human)
--      blocked -> escalate to human
-- ============================================================
CREATE OR REPLACE FUNCTION oracle_route_verdict()
RETURNS TRIGGER AS $$
DECLARE
  v_builder_agent TEXT;
  v_consecutive   INTEGER;
BEGIN
  SELECT builder_agent INTO v_builder_agent
  FROM oracle_queue WHERE id = NEW.queue_id;

  IF NEW.verdict = 'pass' THEN
    -- Reset circuit breaker
    INSERT INTO oracle_circuit_breaker (project_slug, consecutive_failures, updated_at)
    VALUES (NEW.project_slug, 0, now())
    ON CONFLICT (project_slug)
    DO UPDATE SET consecutive_failures = 0, updated_at = now();

    -- Signal success to the coordinator
    INSERT INTO agent_scratchpad (from_agent, to_agent, message_type, priority, subject, content)
    VALUES (
      'oracle', 'brain', 'oracle_verdict', 'high',
      'Oracle Approved: ' || NEW.project_slug,
      'verdict=pass' ||
      E'\nproject=' || NEW.project_slug ||
      E'\nverdict_id=' || NEW.id::text ||
      E'\nfunctions_tested=' || COALESCE(NEW.functions_tested::text, '[]') ||
      E'\nmagicians_tell=' || COALESCE(NEW.magicians_tell, 'no trick detected')
    );
    UPDATE oracle_queue SET status = 'done', completed_at = now() WHERE id = NEW.queue_id;

  ELSIF NEW.verdict = 'fail' THEN
    -- Increment circuit breaker
    INSERT INTO oracle_circuit_breaker (project_slug, consecutive_failures, last_failure_at, updated_at)
    VALUES (NEW.project_slug, 1, now(), now())
    ON CONFLICT (project_slug)
    DO UPDATE SET
      consecutive_failures = oracle_circuit_breaker.consecutive_failures + 1,
      last_failure_at = now(),
      updated_at = now()
    RETURNING consecutive_failures INTO v_consecutive;

    IF v_consecutive >= 3 THEN
      -- Circuit breaker tripped. Escalate to human.
      INSERT INTO agent_scratchpad (from_agent, to_agent, message_type, priority, subject, content)
      VALUES (
        'oracle', 'brain', 'flag', 'urgent',
        'Stuck: ' || NEW.project_slug || ' needs human',
        'Circuit breaker: ' || v_consecutive::text || ' consecutive fails.' ||
        E'\nbugs=' || COALESCE(NEW.bugs_found::text, '[]') ||
        E'\nBuilder loop not converging. Human intervention required.'
      );
      UPDATE oracle_circuit_breaker
      SET last_escalated_at = now(), escalation_count = escalation_count + 1
      WHERE project_slug = NEW.project_slug;
    ELSE
      -- Route fix instructions back to builder silently. Human sees nothing.
      INSERT INTO agent_scratchpad (from_agent, to_agent, message_type, priority, subject, content)
      VALUES (
        'oracle', v_builder_agent, 'oracle_verdict', 'high',
        'Oracle fail: fix and resubmit ' || NEW.project_slug,
        'verdict=fail (attempt ' || v_consecutive::text || ' of 3 before escalation)' ||
        E'\nbugs_found=' || COALESCE(NEW.bugs_found::text, '[]') ||
        E'\nspec_deviations=' || COALESCE(NEW.spec_deviations::text, '[]') ||
        E'\n---FIX INSTRUCTIONS---\n' ||
        COALESCE(NEW.fix_instructions, 'See bugs_found array.') ||
        E'\n---\nApply fixes. Resubmit to oracle_queue as attempt ' || (v_consecutive + 1)::text
      );
    END IF;
    UPDATE oracle_queue SET status = 'done', completed_at = now() WHERE id = NEW.queue_id;

  ELSIF NEW.verdict = 'blocked' THEN
    -- Oracle couldn't review honestly (deploy down, spec missing, etc).
    INSERT INTO agent_scratchpad (from_agent, to_agent, message_type, priority, subject, content)
    VALUES (
      'oracle', 'brain', 'flag', 'high',
      'Blocked: ' || NEW.project_slug,
      'Oracle could not review honestly.' ||
      E'\nreason=' || COALESCE(NEW.fix_instructions, 'See observations.') ||
      E'\nEscalate if unblocking requires human action.'
    );
    UPDATE oracle_queue SET status = 'done', completed_at = now() WHERE id = NEW.queue_id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_oracle_route_verdict
  AFTER INSERT ON oracle_verdicts
  FOR EACH ROW
  EXECUTE FUNCTION oracle_route_verdict();

-- ============================================================
-- 6. Audit sampler (optional utility)
--    Pull a random sample of recent verdicts for spot-checking.
-- ============================================================
CREATE OR REPLACE FUNCTION oracle_audit_sample(
  p_sample_size INTEGER DEFAULT 5,
  p_window_hours INTEGER DEFAULT 72
)
RETURNS TABLE (
  verdict_id    UUID,
  project_slug  TEXT,
  verdict       TEXT,
  bugs_found    JSONB,
  magicians_tell TEXT,
  signed_at     TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    ov.id,
    ov.project_slug,
    ov.verdict,
    ov.bugs_found,
    ov.magicians_tell,
    ov.signed_at
  FROM oracle_verdicts ov
  WHERE ov.signed_at > now() - (p_window_hours || ' hours')::interval
  ORDER BY random()
  LIMIT p_sample_size;
END;
$$ LANGUAGE plpgsql;
