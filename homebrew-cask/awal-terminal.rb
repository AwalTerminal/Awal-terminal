cask "awal-terminal" do
  version "0.25.1"
  sha256 "1c879e529e4adbd63656d5ebcaaf22e211656b533b04aada37982c7ac36ca059"

  url "https://github.com/AwalTerminal/awal-terminal/releases/download/v#{version}/AwalTerminal.zip"
  name "Awal Terminal"
  desc "LLM-native terminal emulator for macOS"
  homepage "https://awalterminal.github.io/awal-terminal/"

  depends_on macos: ">= :sonoma"

  app "AwalTerminal.app"

  zap trash: [
    "~/.config/awal",
  ]
end
