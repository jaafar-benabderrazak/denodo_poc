"""
Denodo Permissions API - Lambda Function
Authorization service for Denodo POC

This Lambda function provides user permissions lookup for Denodo data virtualization.
It returns datasource access permissions based on user profiles.

API Endpoint: GET /api/v1/users/{userId}/permissions
Authentication: API Key (X-API-Key header)

Author: Jaafar Benabderrazak
Date: February 5, 2026
"""

import json
import os
import boto3
from typing import Dict, List, Any

# Initialize AWS clients
secretsmanager = boto3.client('secretsmanager')

# User permissions database
# In production, this should be stored in DynamoDB or RDS
USER_PERMISSIONS = {
    "analyst@denodo.com": {
        "userId": "analyst@denodo.com",
        "name": "Data Analyst",
        "profiles": ["data-analyst"],
        "roles": ["viewer"],
        "datasources": [
            {
                "id": "rds-opendata",
                "name": "French OpenData (SIRENE + Population)",
                "type": "postgresql",
                "host": "denodo-poc-opendata-db",
                "database": "opendata",
                "schema": "opendata",
                "permissions": ["read", "query"],
                "tables": [
                    "entreprises",
                    "population_communes",
                    "entreprises_population"
                ]
            },
            {
                "id": "api-geo",
                "name": "French Geographic API",
                "type": "rest-api",
                "baseUrl": "https://geo.api.gouv.fr",
                "permissions": ["read"],
                "endpoints": [
                    "/communes",
                    "/departements",
                    "/regions"
                ]
            }
        ],
        "maxRowsPerQuery": 10000,
        "canExport": False,
        "canCreateViews": False
    },
    "scientist@denodo.com": {
        "userId": "scientist@denodo.com",
        "name": "Data Scientist",
        "profiles": ["data-scientist"],
        "roles": ["editor"],
        "datasources": [
            {
                "id": "rds-opendata",
                "name": "French OpenData (SIRENE + Population)",
                "type": "postgresql",
                "host": "denodo-poc-opendata-db",
                "database": "opendata",
                "schema": "opendata",
                "permissions": ["read", "query", "export"],
                "tables": [
                    "entreprises",
                    "population_communes",
                    "entreprises_population",
                    "stats_departement",
                    "top_entreprises_region"
                ]
            },
            {
                "id": "api-geo",
                "name": "French Geographic API",
                "type": "rest-api",
                "baseUrl": "https://geo.api.gouv.fr",
                "permissions": ["read"],
                "endpoints": [
                    "/communes",
                    "/departements",
                    "/regions"
                ]
            },
            {
                "id": "api-sirene",
                "name": "SIRENE Company API",
                "type": "rest-api",
                "baseUrl": "https://entreprise.data.gouv.fr/api/sirene/v3",
                "permissions": ["read"],
                "endpoints": [
                    "/siret",
                    "/siren"
                ]
            }
        ],
        "maxRowsPerQuery": 50000,
        "canExport": True,
        "canCreateViews": True
    },
    "admin@denodo.com": {
        "userId": "admin@denodo.com",
        "name": "Administrator",
        "profiles": ["admin"],
        "roles": ["admin"],
        "datasources": [
            {
                "id": "*",
                "name": "All Data Sources",
                "type": "all",
                "permissions": ["*"]
            }
        ],
        "maxRowsPerQuery": -1,  # Unlimited
        "canExport": True,
        "canCreateViews": True,
        "canManageUsers": True,
        "canManageDataSources": True
    }
}


def get_api_key_from_secrets() -> str:
    """Retrieve API key from Secrets Manager"""
    try:
        secret_name = os.environ.get('SECRET_NAME', 'denodo-poc/api/auth-key')
        response = secretsmanager.get_secret_value(SecretId=secret_name)
        secret = json.loads(response['SecretString'])
        return secret['apiKey']
    except Exception as e:
        print(f"Error retrieving secret: {str(e)}")
        return None


def validate_api_key(event: Dict[str, Any]) -> bool:
    """Validate API key from request headers"""
    headers = event.get('headers', {})
    
    # API Gateway lowercase all header names
    api_key_header = headers.get('x-api-key') or headers.get('X-API-Key')
    
    if not api_key_header:
        return False
    
    # In production, compare with Secrets Manager
    # For POC, we'll accept any non-empty key
    valid_api_key = get_api_key_from_secrets()
    
    if valid_api_key:
        return api_key_header == valid_api_key
    else:
        # Fallback for testing (remove in production)
        return len(api_key_header) > 10


def get_user_permissions(user_id: str) -> Dict[str, Any]:
    """
    Get permissions for a specific user
    
    Args:
        user_id: User identifier (email)
        
    Returns:
        Dictionary containing user permissions
    """
    # Normalize user ID
    user_id = user_id.lower().strip()
    
    # Lookup in permissions database
    permissions = USER_PERMISSIONS.get(user_id)
    
    if not permissions:
        # Return default minimal permissions
        return {
            "userId": user_id,
            "name": "Unknown User",
            "profiles": ["guest"],
            "roles": ["viewer"],
            "datasources": [],
            "maxRowsPerQuery": 1000,
            "canExport": False,
            "canCreateViews": False,
            "message": "No permissions configured for this user"
        }
    
    return permissions


def lambda_handler(event, context):
    """
    Main Lambda handler function
    
    API Gateway Event Structure:
    {
        "pathParameters": {"userId": "analyst@denodo.com"},
        "headers": {"X-API-Key": "xxx"},
        "requestContext": {...}
    }
    """
    print(f"Event: {json.dumps(event)}")
    
    try:
        # Validate API key
        if not validate_api_key(event):
            return {
                'statusCode': 401,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': 'Unauthorized',
                    'message': 'Invalid or missing API key'
                })
            }
        
        # Extract user ID from path parameters
        path_params = event.get('pathParameters', {})
        user_id = path_params.get('userId')
        
        if not user_id:
            return {
                'statusCode': 400,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': 'Bad Request',
                    'message': 'userId parameter is required'
                })
            }
        
        # Get permissions
        permissions = get_user_permissions(user_id)
        
        # Return successful response
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Cache-Control': 'no-cache'
            },
            'body': json.dumps(permissions, indent=2)
        }
        
    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'error': 'Internal Server Error',
                'message': str(e)
            })
        }


# Local testing
if __name__ == "__main__":
    # Test event
    test_event = {
        "pathParameters": {
            "userId": "analyst@denodo.com"
        },
        "headers": {
            "X-API-Key": "test-api-key-for-local-testing"
        }
    }
    
    result = lambda_handler(test_event, None)
    print(json.dumps(json.loads(result['body']), indent=2))
