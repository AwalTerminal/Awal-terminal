cask "awal-terminal" do
  version "0.13.0"
  sha256 "7994d1a13d9c92ac5fe8129aaaea78affa18890e8170eb68923e0bd8c75235bf"

  url "https://github.com/AwalTerminal/Awal-terminal/releases/download/v#{version}/AwalTerminal.zip"
  name "Awal Terminal"
  desc "LLM-native terminal emulator for macOS"
  homepage "https://awalterminal.github.io/Awal-terminal/"

  depends_on macos: ">= :sonoma"

  app "AwalTerminal.app"

  zap trash: [
    "~/.config/awal",
  ]
end
