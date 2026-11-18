"""ChordNet: a small CNN + bidirectional GRU over the log-frequency spectrogram, 25 classes per frame."""
import torch
import torch.nn as nn
from features import NBINS, N_CLASSES


class ChordNet(nn.Module):
    def __init__(self, hidden=160, width=24):
        super().__init__()
        c = width

        def block(i, o, k=3):
            return nn.Sequential(nn.Conv2d(i, o, k, padding=k // 2), nn.BatchNorm2d(o), nn.ReLU())
        self.conv = nn.Sequential(
            block(1, c, 5), block(c, c), nn.MaxPool2d((1, 2)),           # 150 → 75 bins
            block(c, 2 * c), block(2 * c, 2 * c), nn.MaxPool2d((1, 3)),  # → 25
            block(2 * c, 4 * c), nn.Dropout(0.2),
        )
        self.proj = nn.Sequential(nn.Linear(4 * c * (NBINS // 6), 2 * hidden), nn.ReLU(), nn.Dropout(0.3))
        self.gru = nn.GRU(2 * hidden, hidden, batch_first=True, bidirectional=True)
        self.out = nn.Linear(2 * hidden, N_CLASSES)

    def forward(self, x):                      # x: [B, T, NBINS]
        b, t, f = x.shape
        h = self.conv(x.unsqueeze(1))          # [B, C, T, F']
        h = h.permute(0, 2, 1, 3).reshape(b, t, -1)
        h = self.proj(h)
        h, _ = self.gru(h)
        return self.out(h)                     # logits [B, T, 25]


if __name__ == '__main__':
    m = ChordNet()
    print(sum(p.numel() for p in m.parameters()), 'parameters')
