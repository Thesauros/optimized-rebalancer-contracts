#!/bin/bash

# Thesauros Documentation Build Script
# Author: Thesauros Team
# Version: 1.0.0

set -e  # Stop on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Output functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check dependencies
check_dependencies() {
    print_info "Checking dependencies..."
    
    # Check Node.js
    if ! command -v node &> /dev/null; then
        print_error "Node.js is not installed. Install Node.js version 16 or higher."
        exit 1
    fi
    
    # Check npm
    if ! command -v npm &> /dev/null; then
        print_error "npm is not installed."
        exit 1
    fi
    
    # Check GitBook CLI
    if ! command -v gitbook &> /dev/null; then
        print_warning "GitBook CLI is not installed. Installing..."
        npm install -g gitbook-cli
    fi
    
    print_success "All dependencies are installed"
}

# Build documentation
build_documentation() {
    print_info "Starting Thesauros documentation build..."
    
    # Navigate to docs folder
    cd docs
    
    # Install GitBook dependencies
    print_info "Installing GitBook dependencies..."
    gitbook install
    
    # Build documentation
    print_info "Building documentation..."
    gitbook build
    
    # Build PDF
    print_info "Building PDF documentation..."
    gitbook pdf ./ ../rebalance-finance-docs.pdf
    
    # Build EPUB
    print_info "Building EPUB documentation..."
    gitbook epub ./ ../rebalance-finance-docs.epub
    
    # Return to root folder
    cd ..
    
    print_success "Documentation built successfully!"
}

# Create archive
create_archive() {
    print_info "Creating documentation archive..."
    
    # Create archive with web version
    tar -czf rebalance-finance-docs-web.tar.gz -C docs/_book .
    
    print_success "Archive created: rebalance-finance-docs-web.tar.gz"
}

# Clean up temporary files
cleanup() {
    print_info "Cleaning up temporary files..."
    
    # Remove GitBook temporary files
    if [ -d "docs/node_modules" ]; then
        rm -rf docs/node_modules
    fi
    
    print_success "Cleanup completed"
}

# Show information about built files
show_results() {
    print_info "Built files:"
    echo "  📁 docs/_book/ - Web version of documentation"
    echo "  📄 rebalance-finance-docs.pdf - PDF version"
    echo "  📄 rebalance-finance-docs.epub - EPUB version"
    echo "  📦 rebalance-finance-docs-web.tar.gz - Web version archive"
    
    print_info "File sizes:"
    if [ -f "rebalance-finance-docs.pdf" ]; then
        echo "  PDF: $(du -h rebalance-finance-docs.pdf | cut -f1)"
    fi
    if [ -f "rebalance-finance-docs.epub" ]; then
        echo "  EPUB: $(du -h rebalance-finance-docs.epub | cut -f1)"
    fi
    if [ -f "rebalance-finance-docs-web.tar.gz" ]; then
        echo "  Web Archive: $(du -h rebalance-finance-docs-web.tar.gz | cut -f1)"
    fi
}

# Main function
main() {
    echo "=========================================="
    echo "  Thesauros Documentation Builder"
    echo "=========================================="
    echo ""
    
    # Check arguments
    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --help, -h     Show this help"
        echo "  --clean        Clean temporary files only"
        echo "  --no-cleanup   Don't clean temporary files"
        echo ""
        echo "Examples:"
        echo "  $0              # Full build with cleanup"
        echo "  $0 --clean      # Cleanup only"
        echo "  $0 --no-cleanup # Build without cleanup"
        exit 0
    fi
    
    if [ "$1" = "--clean" ]; then
        cleanup
        exit 0
    fi
    
    # Execute build
    check_dependencies
    build_documentation
    create_archive
    
    # Cleanup (if not --no-cleanup)
    if [ "$1" != "--no-cleanup" ]; then
        cleanup
    fi
    
    show_results
    
    echo ""
    print_success "Documentation build completed!"
    echo ""
    echo "To view web version, open docs/_book/index.html"
    echo "To publish, use files in docs/_book/ folder"
}

# Run main function
main "$@" 