from flask import Flask, jsonify
import requests
import time
import random

app = Flask(__name__)

INVENTORY_URL = "http://localhost:5002"

@app.route("/checkout", methods=["GET", "POST"])
def checkout():
    item_id = random.choice(["SKU-001", "SKU-042", "SKU-099", "SKU-777"])
    resp = requests.get(f"{INVENTORY_URL}/inventory/{item_id}")
    stock = resp.json()

    if stock["available"]:
        time.sleep(random.uniform(0.05, 0.15))
        return jsonify({"status": "confirmed", "item": item_id, "stock": stock["quantity"]})
    else:
        return jsonify({"status": "out_of_stock", "item": item_id}), 409


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
