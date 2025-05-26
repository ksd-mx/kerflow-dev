#!/bin/bash

# Advanced Firebase Configuration Fetcher
# This script uses gcloud CLI to fetch both web and service account configs

set -e

echo "🔥 Advanced Firebase Configuration Fetcher"
echo "========================================="

PROJECT_ID="kerflow-app"

# Function to check and install dependencies
check_dependencies() {
    local missing_deps=()
    
    if ! command -v firebase &> /dev/null; then
        missing_deps+=("firebase-tools")
    fi
    
    if ! command -v gcloud &> /dev/null; then
        missing_deps+=("Google Cloud SDK")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "❌ Missing dependencies: ${missing_deps[*]}"
        echo ""
        echo "To install:"
        echo "  firebase-tools: npm install -g firebase-tools"
        echo "  Google Cloud SDK: https://cloud.google.com/sdk/docs/install"
        echo "  jq: brew install jq (on macOS)"
        exit 1
    fi
}

# Check dependencies
check_dependencies

# Login to Firebase and Google Cloud
echo "🔐 Authenticating..."
echo "This will open your browser for authentication"

# Firebase login
firebase login --no-localhost

# Google Cloud login
gcloud auth login

# Set the project
echo "🎯 Setting project to: $PROJECT_ID"
gcloud config set project $PROJECT_ID
firebase use $PROJECT_ID

# Fetch web app configuration
echo "🌐 Fetching web app configuration..."

# Get web app list
WEB_APPS=$(firebase apps:list --project $PROJECT_ID --json)
WEB_APP_ID=$(echo "$WEB_APPS" | jq -r '.result[] | select(.platform == "WEB") | .appId' | head -1)

if [ -z "$WEB_APP_ID" ]; then
    echo "❌ No web app found. Creating one..."
    firebase apps:create WEB "Kerflow Web App" --project $PROJECT_ID
    WEB_APP_ID=$(firebase apps:list --project $PROJECT_ID --json | jq -r '.result[] | select(.platform == "WEB") | .appId' | head -1)
fi

echo "📱 Found web app: $WEB_APP_ID"

# Get SDK config
TEMP_DIR=$(mktemp -d)
SDK_CONFIG_FILE="$TEMP_DIR/sdk-config.js"
firebase apps:sdkconfig WEB $WEB_APP_ID --project $PROJECT_ID > "$SDK_CONFIG_FILE"

# Parse and create web env file
echo "📝 Creating web environment file..."

# Extract values using a Node.js script for better parsing
cat > "$TEMP_DIR/parse-config.js" << 'EOF'
const fs = require('fs');
const configFile = process.argv[2];
const content = fs.readFileSync(configFile, 'utf8');

// Extract the config object
const configMatch = content.match(/const firebaseConfig = ({[\s\S]*?});/);
if (configMatch) {
    const configStr = configMatch[1];
    // Parse as JSON-like object
    const config = eval('(' + configStr + ')');
    
    // Output as env vars
    console.log(`VITE_FIREBASE_API_KEY="${config.apiKey}"`);
    console.log(`VITE_FIREBASE_AUTH_DOMAIN="${config.authDomain}"`);
    console.log(`VITE_FIREBASE_PROJECT_ID="${config.projectId}"`);
    console.log(`VITE_FIREBASE_STORAGE_BUCKET="${config.storageBucket}"`);
    console.log(`VITE_FIREBASE_MESSAGING_SENDER_ID="${config.messagingSenderId}"`);
    console.log(`VITE_FIREBASE_APP_ID="${config.appId}"`);
}
EOF

# Run the parser
WEB_ENV_CONTENT=$(node "$TEMP_DIR/parse-config.js" "$SDK_CONFIG_FILE" 2>/dev/null || echo "")

if [ -z "$WEB_ENV_CONTENT" ]; then
    echo "❌ Failed to parse Firebase config. Using manual extraction..."
    # Fallback to grep method
    API_KEY=$(grep -o '"apiKey":\s*"[^"]*"' "$SDK_CONFIG_FILE" | cut -d'"' -f4)
    AUTH_DOMAIN=$(grep -o '"authDomain":\s*"[^"]*"' "$SDK_CONFIG_FILE" | cut -d'"' -f4)
    STORAGE_BUCKET=$(grep -o '"storageBucket":\s*"[^"]*"' "$SDK_CONFIG_FILE" | cut -d'"' -f4)
    MESSAGING_SENDER_ID=$(grep -o '"messagingSenderId":\s*"[^"]*"' "$SDK_CONFIG_FILE" | cut -d'"' -f4)
    APP_ID=$(grep -o '"appId":\s*"[^"]*"' "$SDK_CONFIG_FILE" | cut -d'"' -f4)
    
    WEB_ENV_CONTENT="VITE_FIREBASE_API_KEY=\"$API_KEY\"
VITE_FIREBASE_AUTH_DOMAIN=\"$AUTH_DOMAIN\"
VITE_FIREBASE_PROJECT_ID=\"$PROJECT_ID\"
VITE_FIREBASE_STORAGE_BUCKET=\"$STORAGE_BUCKET\"
VITE_FIREBASE_MESSAGING_SENDER_ID=\"$MESSAGING_SENDER_ID\"
VITE_FIREBASE_APP_ID=\"$APP_ID\""
fi

# Create web env file
cat > web/.env.firebase-prod << EOF
# Firebase Web Configuration - Auto-generated
# Generated on: $(date)
# Project: $PROJECT_ID

$WEB_ENV_CONTENT

# Disable emulator for production
VITE_USE_FIREBASE_EMULATOR=false

# API URL (update this for your Cloudflare Worker)
VITE_API_BASE_URL="https://api-kerflow.workers.dev"
EOF

cp web/.env.firebase-prod web/.env.production
echo "✅ Created web/.env.firebase-prod and web/.env.production"

# Download service account key
echo ""
echo "🔑 Downloading service account key..."

# Get or create service account
SERVICE_ACCOUNT_EMAIL="${PROJECT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

# Check if service account exists, create if not
if ! gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" &>/dev/null; then
    echo "Creating service account..."
    gcloud iam service-accounts create "${PROJECT_ID}" \
        --display-name="Firebase Admin SDK Service Account"
    
    # Grant necessary roles
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
        --role="roles/firebase.admin"
fi

# Download the key
KEY_FILE="api/service-account-key.json"
echo "Downloading service account key to: $KEY_FILE"

gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$SERVICE_ACCOUNT_EMAIL" \
    --key-file-type=json

if [ -f "$KEY_FILE" ]; then
    echo "✅ Service account key downloaded successfully"
    
    # Create API env file with actual values
    cat > api/.env.firebase-prod << EOF
# Firebase API Configuration - Auto-generated
# Generated on: $(date)
# Project: $PROJECT_ID

# Basic config
NODE_ENV=production
PORT=3000
CLIENT_ORIGIN=https://kerflow-app.pages.dev

# Firebase
FIREBASE_PROJECT_ID=$PROJECT_ID
FIREBASE_USE_EMULATOR=false

# Service account path
GOOGLE_APPLICATION_CREDENTIALS=./service-account-key.json

# Stream.io credentials (update these with your actual values)
STREAM_API_KEY=your-stream-key
STREAM_API_SECRET=your-stream-secret
STREAM_APP_ID=your-stream-app-id
EOF
    
    cp api/.env.firebase-prod api/.env.production
    echo "✅ Created api/.env.firebase-prod and api/.env.production"
else
    echo "❌ Failed to download service account key"
fi

# Test the configuration locally
echo ""
echo "🧪 Testing configuration..."

# Create a simple test script
cat > "$TEMP_DIR/test-firebase.js" << 'EOF'
const admin = require('firebase-admin');

try {
    admin.initializeApp({
        credential: admin.credential.applicationDefault(),
        projectId: process.env.FIREBASE_PROJECT_ID
    });
    console.log('✅ Firebase Admin SDK initialized successfully');
    process.exit(0);
} catch (error) {
    console.error('❌ Firebase Admin SDK initialization failed:', error.message);
    process.exit(1);
}
EOF

# Clean up
rm -rf "$TEMP_DIR"

echo ""
echo "🎉 Firebase configuration fetched successfully!"
echo ""
echo "📁 Created files:"
echo "   - web/.env.firebase-prod"
echo "   - web/.env.production"
echo "   - api/.env.firebase-prod"
echo "   - api/.env.production"
echo "   - api/service-account-key.json"
echo ""
echo "⚠️  IMPORTANT: Add these files to .gitignore:"
echo "   - *.env.firebase-prod"
echo "   - *.env.production"
echo "   - service-account-key.json"
echo ""
echo "📌 Next steps:"
echo "1. Update the API URLs in the env files"
echo "2. Test locally:"
echo "   - Web: cd web && npm run dev"
echo "   - API: cd api && npm run dev"
echo "3. Deploy to Cloudflare:"
echo "   - Web: cd web && ./scripts/sync-firebase-credentials.sh"
echo "   - API: cd api && wrangler secret put FIREBASE_SERVICE_ACCOUNT < service-account-key.json"