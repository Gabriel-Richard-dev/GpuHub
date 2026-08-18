"""Treino propositalmente pesado (CNN em dados sintéticos), pra comparar
GPUHUB_TARGET=local numa máquina sem GPU contra GPUHUB_TARGET=hub.

GPUHUB_TARGET=local python examples/heavy_train_example.py --steps 30
GPUHUB_TARGET=hub GPUHUB_ADDRESS=<ip-do-hub> python examples/heavy_train_example.py --steps 30

Requer torch: pip install -e ".[examples]"
"""
import argparse
import time

import gpuhub


def build_model(num_classes=10):
    import torch.nn as nn

    def block(cin, cout):
        return nn.Sequential(
            nn.Conv2d(cin, cout, 3, padding=1),
            nn.BatchNorm2d(cout),
            nn.ReLU(inplace=True),
            nn.Conv2d(cout, cout, 3, padding=1),
            nn.BatchNorm2d(cout),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),
        )

    return nn.Sequential(
        block(3, 64),
        block(64, 128),
        block(128, 256),
        block(256, 512),
        nn.AdaptiveAvgPool2d(1),
        nn.Flatten(),
        nn.Linear(512, num_classes),
    )


@gpuhub.gpu_task(num_gpus=1)
def train(steps: int, batch_size: int, image_size: int):
    import torch
    import torch.nn.functional as F

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"treinando em: {device}")

    model = build_model().to(device)
    optimizer = torch.optim.SGD(model.parameters(), lr=0.01, momentum=0.9)

    started = time.time()
    for step in range(steps):
        step_start = time.time()

        # dados sintéticos só pra gerar carga de treino de verdade (conv pesada)
        images = torch.randn(batch_size, 3, image_size, image_size, device=device)
        labels = torch.randint(0, 10, (batch_size,), device=device)

        optimizer.zero_grad()
        loss = F.cross_entropy(model(images), labels)
        loss.backward()
        optimizer.step()

        step_time = time.time() - step_start
        print(
            f"step {step + 1}/{steps}  loss={loss.item():.4f}  "
            f"{step_time:.2f}s/step  {batch_size / step_time:.1f} imgs/s"
        )

    total = time.time() - started
    return {"device": device, "total_seconds": total, "steps": steps}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--steps", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--image-size", type=int, default=128)
    parser.add_argument("--user", default="gabriel")
    args = parser.parse_args()

    gpuhub.connect()  # lê GPUHUB_TARGET / GPUHUB_ADDRESS do ambiente

    summary = train.run(
        args.steps,
        args.batch_size,
        args.image_size,
        user=args.user,
        name="heavy-cnn-benchmark",
    )
    print()
    print(f"terminou em {summary['device']}: {summary['total_seconds']:.1f}s "
          f"para {summary['steps']} steps")
