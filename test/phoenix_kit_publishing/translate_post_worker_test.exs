defmodule PhoenixKit.Modules.Publishing.TranslatePostWorkerTest do
  use PhoenixKitPublishing.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.Workers.TranslatePostWorker

  # ============================================================================
  # timeout/1 — Dynamic timeout scaling
  # ============================================================================

  describe "timeout/1" do
    test "scales with number of target languages" do
      job = build_job(%{"target_languages" => Enum.map(1..10, &"lang-#{&1}")})
      timeout_ms = TranslatePostWorker.timeout(job)
      # 10 * 1.5 = 15 minutes
      assert timeout_ms == :timer.minutes(15)
    end

    test "uses minimum of 15 minutes for small language counts" do
      job = build_job(%{"target_languages" => ["de", "fr"]})
      timeout_ms = TranslatePostWorker.timeout(job)
      # 2 * 1.5 = 3, but min is 15
      assert timeout_ms == :timer.minutes(15)
    end

    test "scales up for many languages" do
      langs = Enum.map(1..39, &"lang-#{&1}")
      job = build_job(%{"target_languages" => langs})
      timeout_ms = TranslatePostWorker.timeout(job)
      # 39 * 1.5 = 58.5, ceil = 59
      assert timeout_ms == :timer.minutes(59)
    end

    test "handles single language" do
      job = build_job(%{"target_languages" => ["de"]})
      timeout_ms = TranslatePostWorker.timeout(job)
      assert timeout_ms == :timer.minutes(15)
    end

    defp build_job(args) do
      %Oban.Job{args: args}
    end
  end

  # ============================================================================
  # create_job/3 — Job-args construction (no Oban insertion)
  # ============================================================================

  describe "create_job/3" do
    test "builds an Oban.Job changeset with required args" do
      changeset = TranslatePostWorker.create_job("docs", "post-uuid")

      assert %Ecto.Changeset{} = changeset
      args = Ecto.Changeset.get_field(changeset, :args)
      assert args["group_slug"] == "docs"
      assert args["post_uuid"] == "post-uuid"
    end

    test "includes endpoint_uuid when provided" do
      changeset =
        TranslatePostWorker.create_job("docs", "post-uuid", endpoint_uuid: "endpoint-1")

      args = Ecto.Changeset.get_field(changeset, :args)
      assert args["endpoint_uuid"] == "endpoint-1"
    end

    test "includes target_languages when provided" do
      changeset =
        TranslatePostWorker.create_job("docs", "post-uuid", target_languages: ~w(es fr de))

      args = Ecto.Changeset.get_field(changeset, :args)
      assert args["target_languages"] == ~w(es fr de)
    end

    test "drops nil-valued opts (no defaults written into args)" do
      changeset = TranslatePostWorker.create_job("docs", "post-uuid", endpoint_uuid: nil)
      args = Ecto.Changeset.get_field(changeset, :args)
      refute Map.has_key?(args, "endpoint_uuid")
    end

    test "passes through user_uuid + version + prompt_uuid + source_language" do
      changeset =
        TranslatePostWorker.create_job("docs", "post-uuid",
          user_uuid: "user-1",
          version: 2,
          prompt_uuid: "prompt-1",
          source_language: "en"
        )

      args = Ecto.Changeset.get_field(changeset, :args)
      assert args["user_uuid"] == "user-1"
      assert args["version"] == 2
      assert args["prompt_uuid"] == "prompt-1"
      assert args["source_language"] == "en"
    end
  end

  # ============================================================================
  # active_job/1 — DB lookup (uses test sandbox)
  # ============================================================================

  describe "active_job/1" do
    test "returns nil when no active job exists for the given post" do
      assert TranslatePostWorker.active_job("019cce93-bbbb-7000-8000-000000000aaa") == nil
    end
  end
end
