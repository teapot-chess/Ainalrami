defmodule AinalramiVerify.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AinalramiVerify.CLI

  @trf "test/fixtures/disputes/seed735265-r7-p10.trf"
  @moduletag :tmp_dir

  defp run(args) do
    me = self()

    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> send(me, {:code, CLI.run(args)}) end)
        send(me, {:out, out})
      end)

    assert_received {:code, code}
    assert_received {:out, out}
    {code, out, err}
  end

  test "certify, then check: OK", %{tmp_dir: dir} do
    cert = Path.join(dir, "c.json")
    assert {0, _, _} = run(["certify", @trf, "-o", cert])
    assert {0, "OK\n", _} = run(["check", @trf, cert])
  end

  test "check against another TRF: FAIL, exit 1", %{tmp_dir: dir} do
    cert = Path.join(dir, "c.json")
    {0, _, _} = run(["certify", @trf, "-o", cert])
    other = "test/fixtures/disputes/seed8848759-r9-p10.trf"
    assert {1, "FAIL: " <> _, _} = run(["check", other, cert])
  end

  test "rules: bbpPairings' round names C2, exit 1" do
    assert {1, out, _} =
             run(["rules", @trf, "test/fixtures/disputes/seed735265-r7-p10.bbp.pairs"])

    assert out =~ "C2"
  end

  test "rules: a deliberately wrong round names its article" do
    assert {1, out, _} =
             run(["rules", "test/fixtures/articles/C12.trf", "test/fixtures/articles/C12.pairs"])

    assert out =~ "C12"
  end

  test "pair writes the -p format" do
    assert {0, out, _} = run(["pair", @trf])
    [count | boards] = String.split(out, "\n", trim: true)
    assert String.to_integer(count) == length(boards)
  end

  test "usage: exit 2" do
    assert {2, _, _} = run(["nonsense"])
  end
end
