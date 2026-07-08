#!/usr/bin/env python3
import argparse
import base64
from pathlib import Path

import boto3
from botocore.signers import RequestSigner


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cluster", default="trino-eks-karpenter")
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--output", default="/tmp/trino-eks-kubeconfig")
    args = parser.parse_args()

    session = boto3.session.Session(region_name=args.region)
    eks = session.client("eks", region_name=args.region)
    cluster = eks.describe_cluster(name=args.cluster)["cluster"]

    sts = session.client("sts", region_name=args.region)
    signer = RequestSigner(
        sts.meta.service_model.service_id,
        args.region,
        "sts",
        "v4",
        session.get_credentials(),
        session.events,
    )
    url = signer.generate_presigned_url(
        {
            "method": "GET",
            "url": "https://sts.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
            "body": {},
            "headers": {"x-k8s-aws-id": args.cluster},
            "context": {},
        },
        region_name=args.region,
        expires_in=900,
        operation_name="",
    )
    token = "k8s-aws-v1." + base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")

    output = Path(args.output)
    output.write_text(
        f"""apiVersion: v1
kind: Config
clusters:
- name: {args.cluster}
  cluster:
    server: {cluster["endpoint"]}
    certificate-authority-data: {cluster["certificateAuthority"]["data"]}
contexts:
- name: {args.cluster}
  context:
    cluster: {args.cluster}
    user: {args.cluster}-token
current-context: {args.cluster}
users:
- name: {args.cluster}-token
  user:
    token: {token}
"""
    )
    print(output)


if __name__ == "__main__":
    main()
