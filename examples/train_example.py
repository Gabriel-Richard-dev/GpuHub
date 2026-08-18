"""Exemplo de treino que roda no GPU Hub.

GPUHUB_TARGET=local python examples/train_example.py
GPUHUB_TARGET=hub GPUHUB_ADDRESS=<ip-do-hub> python examples/train_example.py
"""
import gpuhub

gpuhub.connect()  # lê GPUHUB_TARGET / GPUHUB_ADDRESS do ambiente


@gpuhub.gpu_task(num_gpus=1)
def train(epochs: int):
    import torch

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = torch.nn.Linear(10, 1).to(device)
    optimizer = torch.optim.SGD(model.parameters(), lr=0.01)
    x = torch.randn(64, 10, device=device)
    y = torch.randn(64, 1, device=device)

    for epoch in range(epochs):
        optimizer.zero_grad()
        loss = torch.nn.functional.mse_loss(model(x), y)
        loss.backward()
        optimizer.step()
        print(f"epoch {epoch}: loss={loss.item():.4f} device={device}")

    return {k: v.cpu() for k, v in model.state_dict().items()}


if __name__ == "__main__":
    weights = train.run(epochs=5, user="gabriel", name="exemplo-mlp")
    print("Treino concluído, pesos recebidos de volta:", list(weights.keys()))
