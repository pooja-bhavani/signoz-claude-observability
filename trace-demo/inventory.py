from flask import Flask, jsonify
import time
import random

app = Flask(__name__)

STOCK = {
    "SKU-001": 25,
    "SKU-042": 0,
    "SKU-099": 12,
    "SKU-777": 3,
}

@app.route("/inventory/<item_id>")
def check_inventory(item_id):
    time.sleep(random.uniform(0.01, 0.05))
    quantity = STOCK.get(item_id, 0)
    return jsonify({"item_id": item_id, "available": quantity > 0, "quantity": quantity})


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5002)
