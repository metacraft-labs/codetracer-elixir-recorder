defmodule CanonicalFlowTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "computes and prints the canonical result" do
    assert CanonicalFlow.compute() == 94
    assert capture_io(fn -> assert CanonicalFlow.main() == 94 end) == "94\n"
  end
end
